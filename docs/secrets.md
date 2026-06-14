# Secrets

This is the engineering reference for repo-managed secrets: where they live, how
they are encrypted, how hosts materialize them, and how services consume them.

## Rules

- Do not commit plaintext secret payloads.
- Do not read `data/secrets/**/*.key` contents during routine engineering work.
- Track encrypted `*.age` files, recipient public keys, and Nix metadata under
  `data/secrets/`.
- Treat `data/secrets/default.nix` as the canonical recipient policy.
- Put global deploy, machine, provider runtime, and Terraform material under
  `data/secrets/globals/`.
- Put stack-owned CA, service, NATS, Postgres, VM-stack, and external-provider
  material under `data/secrets/<stack>/`.
- Put stack-scoped external-provider secrets under
  `data/secrets/<stack>/ext/<provider>/`, not under the consuming service.
- Wire every service secret through `age.secrets.<name>` before a service reads
  it.
- For containers, choose `envSecrets` or `fileSecrets` from the image contract,
  not style preference.
- Rotate by updating the encrypted source file, deploying the host, and
  verifying the runtime consumer, not only the `/run/agenix` file.

## Repository Layout

Tracked secret metadata and ciphertext live under `data/secrets/`.

```text
data/secrets/
  default.nix                    recipient policy for managed *.age files
  globals/
    machine/<host>.key.pub       public age recipient for a host
    machine/<host>.key.age       encrypted host age identity
    nixbot/*.key.age             encrypted deploy SSH key material
    ci/*.key.age                 encrypted CI ingress key material
    cloudflare/                  Cloudflare runtime credentials and tunnels
    tf/                          OpenTofu variable secrets
    tailscale/                   host and ephemeral Tailscale auth material
  pvl/
    default.nix                  pvl stack recipient policy helpers
    services.nix                 pvl service-secret recipient policy
    services/<service>/          pvl service-scoped secrets
    ext/<provider>/              pvl external-provider credentials
```

Git ignores plaintext files under `data/secrets/**`. It only re-includes:

- `*.age`
- `*.nix`
- `*.pub`
- `*.crt`

Plaintext siblings may exist briefly for local encryption or decryption flows,
but they must be removed with `scripts/age-secrets.sh clean ...` before the work
is considered complete.

## Recipient Policy

`data/secrets/default.nix` maps each managed encrypted file to public age
recipients:

```nix
"data/secrets/pvl/services/docmost/app-secret.key.age".publicKeys =
  admins ++ pvl-x2;
```

Common recipient groups:

- `admins`: human admin keys from stack user data
- `machines.<host>`: one host age recipient loaded from
  `data/secrets/globals/machine/<host>.key.pub`
- `adminsWithNixbot`: admins plus deploy keys, used for machine identities
- `adminsWithCiHost`: admins, deploy keys, and CI/deploy machines, used for
  deploy-key material

The consuming host's machine recipient must be included for host-local runtime
secrets. If the recipient is missing, activation cannot materialize the
plaintext file for that host.

Stack secret maps should define helpers instead of repeating path strings:

```nix
secrets = rec {
  base = "data/secrets/pvl";
  file = name: "${base}/${name}";
  service = name: "${base}/services/${name}";
  serviceFile = serviceName: fileName: "${service serviceName}/${fileName}";
  serviceKey = serviceName: secretName: serviceFile serviceName "${secretName}.key.age";
  ext = provider: "${base}/ext/${provider}";
  extFile = provider: fileName: "${ext provider}/${fileName}";
  extKey = provider: secretName: extFile provider "${secretName}.key.age";
};
```

Host modules should derive service paths from the injected `stack`, for example
`stack.secrets.service "docmost"`, instead of hard-coding
`data/secrets/<stack>/services/...`.

## Encryption Tooling

Use `scripts/age-secrets.sh` for normal repository-managed secrets.

```sh
scripts/age-secrets.sh encrypt data/secrets/pvl/services/docmost/app-secret.key
scripts/age-secrets.sh decrypt data/secrets/pvl/services/docmost/app-secret.key.age
scripts/age-secrets.sh clean data/secrets/pvl/services/docmost
```

Behavior:

- Default scope is every key in `data/secrets/default.nix`.
- A file or directory argument limits the operation to that managed subtree.
- `encrypt` writes `<plaintext>.age` and does not remove plaintext.
- `decrypt` writes the plaintext sibling and uses `AGE_KEY_FILE`, or
  `~/.ssh/id_ed25519` when unset.
- `clean` deletes plaintext siblings of managed `*.age` files.

Do not manually guess recipients. The script loads them from
`data/secrets/default.nix`.

## Host Materialization

A host exposes encrypted repo secrets through `age.secrets`:

```nix
age.secrets.docmost-app-secret = {
  file = stack.secrets.service "docmost" + "/app-secret.key.age";
  owner = "pvl";
  group = "pvl";
  mode = "0400";
};
```

The attr name controls the default runtime path:

```text
/run/agenix/docmost-app-secret
```

Consumers should use `config.age.secrets.<name>.path` when convenient. If a
module uses a literal `/run/agenix/<name>` path, keep it in the same file as the
matching `age.secrets.<name>` declaration or verify the evaluated path.

Activation-time decryption uses host age identities installed by the deploy
flow. See [`docs/deployment.md`](./deployment.md) for bootstrap and target
activation details.

## Container Secrets

`services.podman-compose` supports two secret injection paths.

### `envSecrets`

Use when the image expects a secret as an environment variable.

```nix
envSecrets.docmost.APP_SECRET = config.age.secrets.docmost-app-secret.path;
```

Runtime behavior:

- The helper reads the source secret at service start.
- It writes a generated env file under `.podman-env-secrets/`.
- The generated compose override adds that file as `env_file`.
- The container receives normal environment variables.

Environment variables are fixed for the lifetime of the container process. A
changed source secret does not mutate an already-running container.

### `fileSecrets`

Use when the image expects a file path or supports a `*_FILE` setting.

```nix
fileSecrets."postgres-password" = {
  file = config.age.secrets.docmost-postgres-password.path;
  services = ["db"];
};
```

Runtime behavior:

- The helper copies the source secret into `.podman-file-secrets/`.
- By default, the generated compose override bind-mounts it read-only at
  `/run/secrets/<name>`.
- `mountPath`, `services`, ownership, mode, and read-only behavior are
  configurable per secret.

A mounted file can change on disk after restaging, but applications usually read
it only at startup. Plan for restart unless the application explicitly reloads
the file.

## Restart Behavior

Podman compose services include secret source information in their restart
stamp.

For age-backed `envSecrets` and `fileSecrets`:

1. The secret entry points at a runtime path such as
   `/run/agenix/docmost-app-secret`.
2. The module matches that path against `config.age.secrets.<name>.path`.
3. The restart stamp includes the SHA-256 hash of
   `config.age.secrets.<name>.file`, which is the encrypted `*.age` source.

Result: rotating a tracked encrypted age file changes the managed unit restart
trigger on the next deploy. This covers the current evaluated uses of
`envSecrets` and `fileSecrets`.

Non-age runtime paths are not content-hashed automatically. Hashing arbitrary
runtime files would either fail during evaluation, require impurity, or read
plaintext secret material. For non-age secret sources, add an explicit
declarative lifecycle knob before relying on automatic restarts.

Manual lifecycle knobs still exist:

- `recreateTag`: force container recreation on the next service run
- `bootTag`: stop and start the stack
- `imageTag`: force image refresh behavior

## Rotation Workflow

Use this checklist for a normal service secret rotation:

1. Generate or obtain the new secret without printing it into logs.
2. Encrypt it to the existing managed `*.age` path.
3. Confirm `data/secrets/default.nix` still has the right recipients.
4. Deploy the consuming host.
5. Verify the evaluated host config still maps:
   - encrypted source: `age.secrets.<name>.file`
   - runtime source: `age.secrets.<name>.path`
   - service consumer: `envSecrets` or `fileSecrets`
6. Verify the application behavior that actually uses the secret.

Useful checks:

```sh
nix eval --raw \
  .#nixosConfigurations.<host>.config.age.secrets.<name>.path

nix eval --json \
  .#nixosConfigurations.<host>.config.services.systemd-user-manager.instances.<unit>.restartTriggers
```

For mounted runtime bytes, verify metadata without printing contents:

```sh
wc -c </run/agenix/<name>
tail -c 1 /run/agenix/<name> | od -An -tx1
```

## Adding A New Service Secret

1. Pick a stable encrypted source path:
   - pvl service: `data/secrets/pvl/services/<service>/<name>.key.age`
   - external provider: `data/secrets/pvl/ext/<provider>/<name>.key.age`
   - certificate/key pairs: use `.crt.age` and `.key.age`
2. Add the exact path to `data/secrets/default.nix` with the consuming machine
   recipient and admin recipients.
3. Encrypt the plaintext payload:

   ```sh
   scripts/age-secrets.sh encrypt data/secrets/<stack>/services/<service>/<name>.key
   scripts/age-secrets.sh clean data/secrets/<stack>/services/<service>
   ```

4. Add `age.secrets.<name>` in the consuming host module.
5. Pass `config.age.secrets.<name>.path` or the matching `/run/agenix/<name>`
   path to the service.
6. For containers:
   - use `envSecrets` for environment-variable-only image contracts
   - use `fileSecrets` for file-based image contracts
7. Evaluate the target host.
8. Deploy and verify the consumer.

## Auditing

Check all evaluated podman-compose secret consumers and whether they map to
`age.secrets`:

```sh
hosts_json=$(nix eval --json .#nixosConfigurations --apply 'x: builtins.attrNames x')
printf '%s' "$hosts_json" | jq -r '.[]' | while read -r host; do
  age_json=$(
    nix eval --json ".#nixosConfigurations.${host}.config.age.secrets" \
      --apply 'secrets: builtins.mapAttrs (n: v: toString (v.path or "/run/agenix/${n}")) secrets'
  )
  pc_json=$(nix eval --json ".#nixosConfigurations.${host}.config.services.podman-compose")
  jq -r --arg host "$host" --argjson age "$age_json" '
    def ageNameFor($p):
      ($age | to_entries | map(select(.value == $p)) | .[0].key // null);
    to_entries[]? as $stack
    | ($stack.value.instances // {}) | to_entries[]? as $inst
    | (
        (($inst.value.fileSecrets // {}) | to_entries[]? |
          {kind:"fileSecrets", path:(.value.file // .value)}),
        (($inst.value.envSecrets // {}) | to_entries[]? as $svc |
          ($svc.value.entries // $svc.value) | to_entries[]? |
          {kind:"envSecrets", path:.value})
      )
    | select(.path != null)
    | .age = ageNameFor(.path)
    | [$host, $stack.key, $inst.key, .kind, .path, (.age // "NO_AGE_MATCH")]
    | @tsv
  ' <<<"$pc_json"
done
```

Any `NO_AGE_MATCH` row needs an explicit lifecycle decision. Either convert it
to an `age.secrets` source or add a deliberate non-age restart/recreate
mechanism.

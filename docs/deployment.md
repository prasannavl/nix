# Deployment

This document describes the deploy path used by `nixbot`.

For the operator trust boundary around CI host-trigger access and arbitrary
`--sha` execution, see
[`docs/nixbot-security-trust-model.md`](./nixbot-security-trust-model.md).

## Deployment Path

1. CI or an operator reaches the CI host as `nixbot@<ci-host>`.
2. CI host runs the packaged `nixbot` binary from the Nix store.
3. `nixbot` updates the CI host source mirror, creates a detached worktree for
   the requested commit, and runs from there.
4. CI host SSHes to target hosts as `nixbot`.
5. `nixos-rebuild --target-host` performs the switch.

## Source Of Truth

- deploy package: `pkgs/tools/nixbot`
- deploy target mapping: `hosts/nixbot.nix`
- package service module: `pkgs/tools/nixbot/nixos-module.nix`
- host policy modules: `hosts/common/all.nix`, `hosts/common/ci.nix`
- repo secrets: `data/secrets/*.age`

## Keys And Identities

There are three separate credential classes:

1. CI host ingress key
   - used by CI or operators to reach the CI host
   - forced-command only
2. Deploy SSH key
   - used by CI host to SSH to managed hosts as `nixbot`
   - installed at `/var/lib/nixbot/.ssh/id_ed25519`
3. Machine age identity
   - used on each host for activation-time secret decryption
   - installed at `/var/lib/nixbot/.age/identity`

## CI host Rules

- The CI host ingress key is high-privilege.
- The forced command must point directly at the packaged `nixbot` binary.
- CI and operators must not upload ad hoc deploy scripts at runtime.
- The persistent repo root on CI host is a source mirror, not the execution tree
  for a deploy run.

## Bootstrap

Bootstrap exists for hosts that do not yet support the normal `nixbot` path.

Use it when the target does not yet have:

- working `nixbot` SSH access
- the shared deploy key installed
- the machine age identity installed
- the repo's normal `nixbot` and agenix model applied

`hosts/nixbot.nix` supports bootstrap-specific fields such as:

- `bootstrapUser`
- `bootstrapKey`
- `bootstrapKeyPath`

The steady-state goal is always the same: later deploys should use normal
`nixbot@host` access, not the bootstrap path.

## Secret Model

- deploy keys and machine identities are stored as age-encrypted repo secrets
- CI host decrypts and uses the deploy key for host access
- each host decrypts secrets using its machine age identity

## Deploy Runtime Notes

- treat CI host-trigger access as privileged production deploy access
- use worktrees for isolation and concurrency, not as a trust boundary
- keep CI host ingress keys tightly scoped

## Remote Build Cache Deploys

By default, `nixbot run`, `nixbot deploy`, and `nixbot build` use local builds.

Use `--build-host <ssh-host>` to build the closure on a remote Nix store using
`ssh-ng://<ssh-host>`. For build-only actions, `nixbot` copies that built
closure back for local inspection and result-link handling. When the build host
cache is configured, that local import comes from the signed cache; otherwise it
falls back to the raw `ssh-ng://` store.

For deploy actions with non-local `--build-host`, the build host entry in
`hosts/nixbot.nix` must resolve through the normal host inventory. `nixbot`
derives the cache URL from the same effective host target used for remote builds
and the repo default `globals.ciCachePort`. The builder's Nix daemon signs
locally built paths through host-side `nix.settings.secret-key-files`; Harmonia
serves the builder's `/nix/store` as the signed binary cache on that port.
`nixbot` verifies that the exact built path is available from the builder cache,
prepares the target from the local orchestrator, makes the target pull the exact
path from the cache, and activates that path over the target SSH context.
Activation, snapshots, rollback, parent readiness, and health checks remain
owned by the local `nixbot` process.

Target-side cache copies temporarily pass the public keys declared by the target
configuration to `nix copy`. This supports the first rollout of cache trust
before the target has activated the new Nix daemon settings.

The default `--build-host-deploy-mode auto` chooses `cache` when `--build-host`
resolves to the configured `globals.ciHost`; otherwise it chooses `local-copy`.
Use `--build-host-deploy-mode local-copy` explicitly when targets cannot reach
the build host cache. In that mode, `nixbot` still builds on `--build-host`,
verifies the signed build-host cache, and uses the local client to relay the
exact signed path from the build-host cache to each target before activation.
Deploy local-copy mode does not import the raw `ssh-ng://` closure into the
operator store; build-only copy-back also prefers the signed build-host cache
when available. `--build-host-deploy-mode cache` is more direct when targets can
reach the build-host Harmonia endpoint.

## Further Reading

- [`docs/nixbot-security-trust-model.md`](./nixbot-security-trust-model.md)
- [`docs/incus-readiness.md`](./incus-readiness.md)
- [`docs/hosts.md`](./hosts.md)

## Detailed Reference

The sections below cover bootstrap mechanics, key exchange, and deploy
internals.

## CI host Wiring Requirements

`hosts/nixbot.nix` declares repo defaults under `globals`, including the default
CI trigger endpoint, CI cache port, and managed repo URL. Explicit CLI flags or
matching environment variables still override them for one run.

In `hosts/common/ci.nix` through `services.nixbot.repos`:

- Add forced-command authorized key entries for repo-specific CI ingress keys.
- Export repo-specific `NIXBOT_REPO_URL` and `NIXBOT_REPO_PATH` before running
  the packaged binary.
- Ensure runtime prerequisites:
  - `/var/lib/nixbot/.ssh` exists, mode `0700`, owner `nixbot`
  - `environment.systemPackages` includes `age` and `jq`
- Ensure nixbot SSH client identity order includes both current and legacy key
  paths during rotation.
- Treat `/var/lib/nixbot/nix` as a source mirror only, not as the execution tree
  for a deploy run. Every run should use its own detached worktree.

## Bootstrap Strategy

In this repo, "bootstrap" means using an already-available admin path to get a
host to the point where the normal `nixbot` deploy path works.

Concretely, bootstrap is needed when a node does not yet satisfy one or more of
these steady-state assumptions:

- `nixbot@host` is not reachable with the shared deploy key
- `/var/lib/nixbot/.ssh/id_ed25519` is not installed on the target
- `/var/lib/nixbot/.age/identity` is not installed on the target
- the host has not yet been switched onto the repo's `nixbot`/agenix model

Bootstrap matters especially for CI host because the CI host is the first trust
anchor for the whole fleet:

- CI and remote operators enter through CI host first, not directly to every
  node
- CI host is where the shared `nixbot` deploy private key is decrypted to
  `/var/lib/nixbot/.ssh/id_ed25519`
- CI host is the host that later SSHes to the rest of the fleet as `nixbot`
- CI host also holds the OpenTofu/Cloudflare runtime secrets used by `tf`

Until CI host itself is bootstrapped, the normal CI -> CI host -> node deploy
chain does not exist yet.

`hosts/nixbot.nix` supports bootstrap fallback fields:

- `bootstrapKey` (defaults + optional per-host override)
- `bootstrapUser`
- `bootstrapKeyPath`

Those fields describe the non-steady-state access path used to get a host onto
the normal `nixbot` path:

- `bootstrapUser`: the account that already exists on the target and can sudo
- `bootstrapKeyPath`: optional direct SSH key path for reaching that bootstrap
  account
- `bootstrapKey`: the private key material that should be installed as
  `/var/lib/nixbot/.ssh/id_ed25519` on the target once bootstrap succeeds

During deploy, script behavior is:

1. Build host system closure.
2. Attempt primary target (`nixbot@host`) shell reachability.
3. If primary shell access fails, run forced-command bootstrap check
   (`check-bootstrap`) via CI host key.
4. If bootstrap check still fails, inject bootstrap key using bootstrap user
   path.
5. Continue deployment (currently via `nixos-rebuild --target-host`).
6. `--bootstrap` skips step 2 probing and forces bootstrap target selection for
   deploy/snapshot/rollback operations.

Important: successful forced-command bootstrap check does not imply general
shell access for `nixos-rebuild --target-host`.

### What "bootstrap check" means

- `check-bootstrap` does not deploy anything.
- It validates whether the configured bootstrap material can be resolved and, in
  the forced-command case, whether the remote CI host-side wrapper can accept
  the request.
- In the current flow this is mainly used when the primary path is
  forced-command-only or otherwise not a normal shell session.

### What "bootstrap fallback" means

- Bootstrap fallback means the deploy script stops trying to use `nixbot@host`
  as the transport for the current step and temporarily uses
  `${bootstrapUser}@host` instead.
- Over that fallback path it can:
  - install the shared `nixbot` deploy private key to
    `/var/lib/nixbot/.ssh/id_ed25519`
  - install the machine age identity to `/var/lib/nixbot/.age/identity`
  - run `nixos-rebuild --target-host` using the bootstrap account's sudo path
- After the host has been switched successfully, later runs are expected to use
  normal `nixbot@host` access instead of bootstrap.

### Why bootstrap is necessary at all

- A brand-new or partially configured host cannot decrypt agenix secrets until
  it has its machine age identity.
- A host also cannot participate in the normal CI host-to-node deploy path until
  it trusts `nixbot` and has the expected SSH material in place.
- Bootstrap breaks that chicken-and-egg problem by using some pre-existing admin
  path just long enough to install the `nixbot` and age identity state that the
  steady-state model requires.

## Key Exchange And Trust Installation

### Static key exchange from configuration

- `users/userdata.nix` is the source of truth for `nixbot.sshKeys` and
  `nixbot.ciSshKeys`.
- `services.nixbot.user.authorizedKeys` installs ordinary public SSH keys
  trusted by the `nixbot` user.
- `services.nixbot.repos.<name>.sshKeys` installs CI ingress keys onto the
  configured repo SSH user, wrapped in a forced command:
  - only the packaged `nixbot` command may run
  - no shell, PTY, forwarding, or user rc files
- This means there are two SSH trust exchanges:
  - all managed nodes learn the normal deploy public keys at activation time
  - the CI host learns the restricted ingress public keys at activation time

### Runtime key exchange during bootstrap

- The private side of the shared deploy key lives encrypted at
  `data/secrets/globals/nixbot/nixbot.key.age`.
- On CI host, `hosts/common/ci.nix` decrypts that file to:
  - `/var/lib/nixbot/.ssh/id_ed25519`
- During bootstrap of another node, `nixbot` may also copy that same private key
  onto the target if `nixbot@target` is not usable yet.
- The exchange happens in `inject_bootstrap_nixbot_key()`:
  - the key is decrypted locally by the deploy script from the configured
    `bootstrapKey`
  - copied to a temporary remote file over the bootstrap account
  - installed remotely as `/var/lib/nixbot/.ssh/id_ed25519`
  - any previous key is preserved as `/var/lib/nixbot/.ssh/id_ed25519_legacy`
- This is the key handoff that lets a fresh node start accepting `nixbot@host`
  deploy connections on later runs.

### Runtime machine-identity exchange during activation

- Machine age identities are not kept in the image or bootstrap account by
  default.
- Instead, `nixbot` injects them just before activation in
  `inject_host_age_identity_key()`.
- The exchange happens as:
  1. decrypt configured `hosts.<node>.ageIdentityKey`
  2. copy it over SSH to a temporary remote file
  3. install it as `/var/lib/nixbot/.age/identity`
  4. run activation, where agenix uses that path to decrypt host secrets
- This is why first deploys must go through the deploy script or an equivalent
  manual copy step.

## End-to-End Secret Flow

1. CI/operator reaches CI host using forced-command ingress key
   (`nixbot-ci-ssh`).
2. CI host uses `nixbot` deploy key (`/var/lib/nixbot/.ssh/id_ed25519`) to SSH
   to target hosts and to decrypt repo-side `nixbot`-recipient `.age` files used
   by deploy tooling.

   - When `--discover-keys` is enabled, the deploy script falls back from the
     primary decrypt identity to `/var/lib/nixbot/.ssh/id_ed25519` and then
     `/var/lib/nixbot/.age/identity`.

3. Before each target activation, `nixbot` injects host-specific machine age
   private key to:
   - `/var/lib/nixbot/.age/identity`
4. Target activation runs agenix with:

   - `age.identityPaths = [ "/var/lib/nixbot/.age/identity" ]`

5. Secrets are materialized on target and access to plaintext is constrained
   with Unix ownership/mode via `age.secrets.<name>.owner/group/mode`.

## Secret Topology By Scope

### Machine identities

- `<desktop-host>`
  - deploy metadata: `hosts/nixbot.nix` ->
    `hosts.<desktop-host>.ageIdentityKey = secretPaths.machine "<desktop-host>"`
  - recipients: admins + current `nixbot` deploy keys
  - runtime path on host: `/var/lib/nixbot/.age/identity`
- `<ci-host>`
  - deploy metadata: `hosts/nixbot.nix` ->
    `hosts.<ci-host>.ageIdentityKey = secretPaths.machine "<ci-host>"`
  - recipients: admins + current `nixbot` deploy keys
  - runtime path on host: `/var/lib/nixbot/.age/identity`
  - this host is also the CI host, so its machine recipient is included on the
    shared CI host deploy-key secret and the CI host Cloudflare/OpenTofu runtime
    secrets
- `<incus-guest>`
  - deploy metadata: `hosts/nixbot.nix` ->
    `hosts.<incus-guest>.ageIdentityKey = secretPaths.machine "<incus-guest>"`
  - recipients: admins + current `nixbot` deploy keys
  - runtime path on host: `/var/lib/nixbot/.age/identity`
  - host also consumes `data/secrets/globals/tailscale/<incus-guest>.key.age`
    directly through `lib/incus-vm.nix`

### CI host identities and secrets

- CI host is the configured `hosts/nixbot.nix` `globals.ciHost` target.
- CI host ingress identity is the SSH key whose public half is listed under the
  relevant `services.nixbot.repos.<name>.sshKeys` entry and forced into the
  packaged `nixbot` binary by `pkgs/tools/nixbot/nixos-module.nix`.
- The private half of that ingress key is stored as
  `data/secrets/globals/ci/nixbot-ci-ssh.key.age`.
  - recipients: admins only
  - consumers: CI or an operator initiating a CI host-triggered deploy
- CI host's downstream deploy identity is the private key in
  `data/secrets/globals/nixbot/nixbot.key.age`.
  - recipients: admins + current `nixbot` deploy keys + the CI host machine age
    recipient
  - runtime path on CI host: `/var/lib/nixbot/.ssh/id_ed25519`
  - trusted by other nodes because `services.nixbot.user.authorizedKeys`
    installs the corresponding public keys into the `nixbot` account
- Optional overlap key:
  - source: `data/secrets/globals/nixbot/nixbot-legacy.key.age`
  - runtime path: `/var/lib/nixbot/.ssh/id_ed25519_legacy`
  - purpose: keep CI host able to reach nodes that still trust the old deploy
    public key during rotation

### Service secrets

- General pattern:
  1. recipient set is declared in `data/secrets/default.nix`
  2. the consumer host exposes the secret through `age.secrets.*`
  3. the consuming service reads the materialized file path, not repo plaintext
- CI host compose services:
  - source files live under `data/secrets/pvl/services/<service>/*.key.age`
  - recipients are admins + the CI host machine age recipient
  - the CI host's imported service module maps them into `age.secrets.*`
  - `services.podman-compose.*.envSecrets` injects them into containers as
    file-backed environment values
- CI host OpenTofu/Cloudflare runtime:
  - source files live under `data/secrets/globals/cloudflare/*.key.age`
  - recipients are admins + the CI host
  - the CI host nixbot service configuration decrypts them to
    `/var/lib/nixbot/secrets/cloudflare-tf/*`
  - `nixbot tf` auto-loads them into the OpenTofu environment when shell
    variables are absent
- Incus-guest Tailscale auth:
  - source file: `data/secrets/globals/tailscale/<incus-guest>.key.age`
  - recipients: admins + `<incus-guest>`
  - `lib/incus-vm.nix` exposes it as `services.tailscale.authKeyFile`

### Incus guest secret notes

- Incus guests do not currently have a separate Incus-specific secret system.
- They use the same host secret model as any other managed node:
  - machine age identity in `data/secrets/globals/machine/<host>.key.age`
  - optional service secrets encrypted to that guest's machine recipient
- The one shared guest-specific convenience path today is in `lib/incus-vm.nix`:
  - optional Tailscale auth secret at
    `data/secrets/globals/tailscale/<host>.key.age`
  - wired to `services.tailscale.authKeyFile` only if the encrypted file exists
- Incus guest SSH host keys are persisted under `/var/lib/machine/*`, but those
  are runtime-generated host keys, not repo-managed agenix secrets.
- For an Incus guest, the related repo secrets are therefore:
  - `data/secrets/globals/machine/<incus-guest>.key.age`
  - `data/secrets/globals/tailscale/<incus-guest>.key.age`

## Adding A New Machine Or Secret

### New machine identity

1. Generate a new age identity for the host.
2. Commit the public recipient to `data/secrets/globals/machine/<host>.key.pub`.
3. Encrypt the private identity to
   `data/secrets/globals/machine/<host>.key.age`.
4. Add the new `.key.age` entry and its recipients in
   `data/secrets/default.nix`.
5. Point `hosts/nixbot.nix` at that secret with `hosts.<host>.ageIdentityKey`.
6. Re-encrypt managed secrets so any host-specific secrets now include the new
   machine recipient.

### New service secret

1. Create the secret file under `data/secrets/pvl/services/<service>/`.
2. Add the recipient policy in `data/secrets/default.nix`.
3. Wire it into the consuming host with `age.secrets.<name>.file = ...`.
4. Pass `config.age.secrets.<name>.path` to the service, usually through
   `envSecrets` or a `*File` setting.
5. Re-encrypt the managed secrets set.

## Kickstarting From Scratch

Use this order for a clean-room rebuild of the current model.

1. Establish the long-lived human/admin keys in `users/userdata.nix`.
   - These keys must be able to decrypt every machine identity, the CI host
     ingress key, and the CI host deploy key.
2. Generate the shared `nixbot` deploy SSH keypair.
   - public key goes into `users/userdata.nix` (`nixbot.sshKeys`)
   - private key becomes `data/secrets/globals/nixbot/nixbot.key.age`
3. Generate the CI host ingress SSH keypair.
   - public key goes into `users/userdata.nix` (`nixbot.ciSshKeys`)
   - private key becomes `data/secrets/globals/ci/nixbot-ci-ssh.key.age`
4. Generate one machine age identity per host.
   - private identities become `data/secrets/globals/machine/<host>.key.age`
   - public recipients become `data/secrets/globals/machine/<host>.key.pub`
5. Fill in `data/secrets/default.nix`.
   - every managed `*.age` file must have the correct recipient set before
     encryption is trustworthy
6. Create plaintext secret payloads only long enough to encrypt them.
   - use `scripts/age-secrets.sh encrypt data/secrets`
   - then remove plaintext siblings with
     `scripts/age-secrets.sh clean data/secrets`
7. Bootstrap the CI host first.
   - it is the CI host and the only host that can later decrypt the shared
     deploy key and Cloudflare/OpenTofu runtime secrets
   - initial access still depends on the configured bootstrap account in
     `hosts/nixbot.nix` (currently `defaults.bootstrapUser = "pvl"`)
   - once deployed, it becomes the place where `nixbot` holds the shared deploy
     private key and initiates downstream SSH to the rest of the fleet
   - this is the step that creates the CI/operator -> CI host -> fleet trust
     chain; before it, only the bootstrap/admin path exists
8. Validate CI host ingress after the CI host is up.
   - the forced-command key should be able to run the packaged `nixbot` command
   - the CI host should hold `/var/lib/nixbot/.ssh/id_ed25519`
9. Deploy the remaining hosts through `nixbot`.
   - first managed deploy to each host injects `/var/lib/nixbot/.age/identity`
   - after that, agenix can decrypt host-local secrets during activation
10. Only after CI host and machine identities are working, add higher-level
    service secrets.
    - CI host service secrets can be activated once CI host decrypt works
    - Incus-guest Tailscale auth can be activated once that host's machine
      identity is wired and deployable

## Scratch Bootstrap Failure Modes

- If a host is activated out-of-band without first receiving
  `/var/lib/nixbot/.age/identity`, agenix-managed host secrets will not decrypt.
- If the CI host is missing from the recipient list of
  `data/secrets/globals/nixbot/nixbot.key.age`, CI host cannot obtain the
  downstream deploy private key.
- If a service secret omits the consuming machine recipient, activation will
  succeed but the secret file will never materialize on that host.
- If `data/secrets/default.nix` and the committed `*.pub` files diverge,
  `scripts/age-secrets.sh encrypt` may succeed for the wrong recipient set, so
  treat that file as the canonical policy review point.

## Deploy Config Defaults (`hosts/nixbot.nix`)

For local operator overrides, create a sibling local config by replacing the
selected config file's final `.nix` suffix with `.override.nix`. For the default
`hosts/nixbot.nix`, that file is `hosts/nixbot.override.nix`. Nixbot evaluates
the selected config first, then recursively overlays the gitignored override
file when it exists. The override file only needs the partial overrides, for
example `hosts.<name>.target = "...";`. Pass `--no-override` to ignore the
sibling override for one run.

- `defaults.user = "nixbot"`
- `defaults.key = "data/secrets/globals/nixbot/nixbot.key.age"`
- `defaults.bootstrapKey = "data/secrets/globals/nixbot/nixbot.key.age"`
- `defaults.bootstrapUser = "pvl"` (or your chosen bootstrap account)
- `knownHosts = null` means temporary `ssh-keyscan` host pinning.
- `hosts.<name>.ageIdentityKey` can define the host-specific runtime age key
  secret to inject.

## Operational Notes

- `check-bootstrap` validates bootstrap key availability/decryption without
  build/deploy.
- `--discover-keys` controls whether the deploy script falls back from the
  primary decrypt identity to local nixbot and machine identity paths.
  - default `auto`: enabled only when `--age-key-file` / `AGE_KEY_FILE` was not
    set explicitly
  - `--discover-keys` or `--discover-keys=on`: always enable fallback
  - `--discover-keys=off` / `--no-discover-keys`: force strict single-identity
    behavior
- `--bootstrap` forces bootstrap path usage even when primary `user@host` is
  reachable.
- `--dry` prints deploy commands; it does not perform remote activation.
- Per-run bootstrap readiness is cached to avoid duplicate fallback checks
  during snapshot + deploy phases.
- Host age identity injection is idempotent: deploy skips replacement when
  remote key checksum already matches configured `ageIdentityKey`.

## Rotation Runbooks

### Planned Rotation (Overlap-Capable)

1. Generate new keypairs for:
   - `nixbot` deploy/login key
   - `nixbot-ci-ssh` ingress key
2. Add new public keys into `users/userdata.nix` while keeping old keys:
   - append deploy/login keys to `nixbot.sshKeys`
   - append ingress keys to `nixbot.ciSshKeys`
3. Re-encrypt managed age files so both old and new nixbot public keys remain
   recipients:
   - `data/secrets/globals/nixbot/nixbot.key.age`
   - `data/secrets/globals/ci/nixbot-ci-ssh.key.age`
4. Deploy CI host first, then the rest of hosts.
5. Update CI secret `NIXBOT_CI_SSH_KEY` to the new CI host private key.
6. If you run `nixbot` from outside CI host, also rotate
   `NIXBOT_CI_SSH_KEY_PATH` (forced-command bootstrap check key) to the new CI
   host ingress key file.
7. Validate forced-command access and one full deploy run.
8. Remove old public keys from both lists, re-encrypt again, and deploy.

### CI Host First Single-Pass Cutover With Legacy Node Access

Use this when you want CI host on new keys immediately, but some nodes still
only trust the old `nixbot` key.

1. Prepare two deploy key secrets:
   - new key: `data/secrets/globals/nixbot/nixbot.key.age` (or another chosen
     path)
   - legacy key: `data/secrets/globals/nixbot/nixbot-legacy.key.age`
2. Add recipients for the legacy file in `data/secrets/default.nix` so
   `scripts/age-secrets.sh` manages it.
3. Set defaults in `hosts/nixbot.nix` to the new key.
4. Add per-host `key` overrides for nodes that still require legacy auth, for
   example:
   - `hosts.<old-node>.key = "data/secrets/globals/nixbot/nixbot-legacy.key.age";`
5. For nodes that still require old bootstrap injection material, also set:
   - `hosts.<old-node>.bootstrapKey = "data/secrets/globals/nixbot/nixbot-legacy.key.age";`
6. Deploy CI host and switch CI ingress key to the new CI host key.
7. If applicable, switch `NIXBOT_CI_SSH_KEY_PATH` for local orchestrator runs to
   the new CI host ingress key.
8. Run deploys in phase 2 to migrate old nodes onto new public key trust.
9. Remove per-host legacy `key` and `bootstrapKey` overrides, remove legacy
   secret material, re-encrypt recipients without legacy keys.

Important: this flow is for controlled migration. If compromise is suspected, do
revoke-first incident rotation instead of overlap.

### Machine Age Identity Rotation (Per Host)

Default policy: no legacy overlap required.

Reason: deploy injects host machine key immediately before activation, so
activation always has the current identity.

Single-step rotation:

1. Generate new host machine keypair.
2. Re-encrypt `data/secrets/globals/machine/<host>.key.age` with admin/deployer
   recipients.
3. Update any host secret recipients in `data/secrets/default.nix` to new
   machine public key.
4. Deploy host; script injects new `/var/lib/nixbot/.age/identity` before
   activation.

Optional overlap (only for unusual partial/out-of-band flows):

1. Keep previous key as `/var/lib/nixbot/.age/identity_legacy`.
2. Temporarily set
   `age.identityPaths = [ "/var/lib/nixbot/.age/identity"
   "/var/lib/nixbot/.age/identity_legacy" ]`.
3. Encrypt host secrets to both old and new machine recipients.
4. After successful migration, remove legacy recipient and legacy file/path.

## Related Docs

- `docs/nixbot-security-trust-model.md`: Operator trust boundary and arbitrary
  SHA policy.
- `docs/services.md`: Native service pattern.
- `docs/podman-compose.md`: Podman compose container workloads.
- `docs/incus-vms.md`: Incus guest lifecycle.
- `docs/incus-readiness.md`: Readiness checks and deploy barriers for Incus
  guests.
- `docs/systemd-user-manager.md`: Deploy-time user-service bridge module.

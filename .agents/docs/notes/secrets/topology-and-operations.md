# Secrets Topology And Operations

## Scope

Canonical secret topology, bootstrap order, and managed secret operations.

## Durable model

- Host activation decrypt uses the machine-specific age identity at
  `/var/lib/nixbot/.age/identity`, not the deploy SSH key.
- CI host forced-command ingress and downstream deploy SSH are separate trust
  domains.
- Service secrets are encrypted to the consuming machine recipient and
  materialized there through `age.secrets.*`.
- Stack-scoped external-provider credentials belong under
  `data/secrets/<stack>/ext/<provider>/`, not under the consuming service tree.
- Bootstrap means moving a host onto the normal `nixbot` deploy model when that
  steady-state path does not exist yet.

## Bootstrap order

1. Define admin and `nixbot` public keys.
2. Generate and encrypt CI host ingress private key material.
3. Generate and encrypt the shared `nixbot` deploy private key.
4. Generate one machine age identity per host.
5. Commit machine recipients.
6. Update recipient policy in `data/secrets/default.nix`.
7. Encrypt managed secrets.
8. Clean plaintext siblings.
9. Bootstrap CI host first.
10. Bootstrap the rest of the fleet through the standard deploy path.

## Managed secret operations

- `scripts/age-secrets.sh` is the canonical entrypoint.
- Managed plaintext cleanup is an explicit `clean` operation.
- `clean` should only remove plaintext siblings of managed `*.age` entries.
- Scope filters may target either a managed directory or a single managed file.
- Decrypt should continue across per-file failures, report them at the end, and
  use the configured identity consistently across the selected set.
- Script defaults should stay centralized in `init_vars`.
- Wrapper-private runtime flags belong in the script's own namespace and
  runtime-shell recursion guards should stay local to the shell-setup path.

## Operator rules

- Keep machine age identity injection as part of the first real deploy to a new
  host.
- Do not rely on the deploy SSH key for host activation decrypt.
- Unmanaged plaintext files are out of scope for `scripts/age-secrets.sh`.
- Do not read or print `data/secrets/**/*.key` contents during routine
  engineering work.
- Preserve exact secret bytes when rotating single-line tokens; do not add a
  trailing newline unless the provider contract requires one.
- Verify the runtime consumer after rotation. A deployed `/run/agenix` file is
  only materialization; the application may still need a restart, reload, or
  provider-side validation.

## Podman secret consumers

- `envSecrets` is for images that require environment variables. The helper
  reads source files at service start and writes generated env files under the
  compose runtime tree.
- `fileSecrets` is for images that accept files or `*_FILE` settings. The helper
  stages files under the compose runtime tree and can mount them under
  `/run/secrets/<name>`.
- Age-backed `envSecrets` and `fileSecrets` include the encrypted source file
  hash in the Podman Compose restart stamp when the runtime path matches an
  evaluated `age.secrets.<name>.path`.
- Non-age runtime secret paths are not content-hashed automatically. Convert
  them to `age.secrets` or add an explicit lifecycle tag before relying on a
  rotation restart.

## Source of truth files

- `data/secrets/default.nix`
- `scripts/age-secrets.sh`
- `hosts/nixbot.nix`
- `pkgs/tools/nixbot/nixos-module.nix`
- `hosts/common/all.nix`
- `hosts/common/ci.nix`
- `lib/incus-vm.nix`
- `docs/secrets.md`
- `docs/deployment.md`

## Provenance

- This note replaces the earlier dated secret-topology and age-secrets operation
  notes.

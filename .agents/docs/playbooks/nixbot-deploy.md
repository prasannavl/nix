# Nixbot Deploy System (AI Reconstruction Spec)

## Goal

Reconstruct a secure deployment system where CI enters CI host using a
forced-command key, while regular `nixbot` SSH key behavior remains normal.

## High-Level Model

- CI -> CI host forced command -> build derivations -> deploy targets.
- Script tries `nixbot@target` first, then bootstrap fallback if needed.

## Security Invariants

- All hosts are on Tailscale.
- CI should have only:
  - Tailscale auth credential scoped to CI host reachability.
  - CI host ingress SSH key (forced-command only).
- CI host ingress key must only run the packaged `nixbot` command from
  `pkgs/tools/nixbot`.
- Regular `nixbot` SSH access is sourced from `users/userdata.nix`
  `nixbot.sshKeys` and installed through `services.nixbot.user.authorizedKeys`.
- CI host stores private deploy key at `/var/lib/nixbot/.ssh/id_ed25519` (from
  `data/secrets/globals/nixbot/nixbot.key.age`).
- Activation-time agenix decrypt uses machine identity
  `/var/lib/nixbot/.age/identity` (host specific), not the deploy SSH key.

## Bootstrap Definition

Bootstrap passes when:

1. `nixbot@host` ingress/fallback checks can be executed.
2. bootstrap key/decrypt material is available at expected paths.

If bootstrap fails, fallback uses configured bootstrap user/key path.

## Source Of Truth Files

- `nixbot`
- `hosts/nixbot.nix`
- `pkgs/tools/nixbot/nixos-module.nix`
- `hosts/common/all.nix`
- `hosts/common/ci.nix`

## CI host Module Requirements (`hosts/common/ci.nix`)

- Define `services.nixbot.repos.<name>` for each repo the host should accept CI
  forced-command ingress for.
- Keep ordinary `nixbot` login/deploy keys in `users/userdata.nix`
  `nixbot.sshKeys`; `hosts/common/all.nix` installs them through
  `services.nixbot.user.authorizedKeys`.
- Let the module generate forced-command wrappers that export `NIXBOT_REPO_URL`
  and `NIXBOT_REPO_PATH` before running the packaged binary.
- Ensure dependencies exist on CI host:
  - `age`, `jq`
- Ensure runtime SSH dir/permissions exist.
- Keep CI host deploy keys managed via `age.secrets.*` paths under
  `/var/lib/nixbot/.ssh`.

## Deploy Mapping (`hosts/nixbot.nix`)

Defaults:

- `user = "nixbot"`
- `key = "data/secrets/globals/nixbot/nixbot.key.age"`

Optional per-host:

- `operatorUser`, `operatorKey`, `bootstrapKey`, `knownHosts`
- `ageIdentityKey` (host machine age identity secret for activation-time
  decrypt)

Defaults may also include:

- `operatorUser`
- `operatorKey`
- `bootstrapKey`

## Runtime Behavior Notes

- Bootstrap-check success does not guarantee generic shell access.
- If bootstrap key preparation restores normal `nixbot@host` access, deploy must
  promote back to the primary route before `nixos-rebuild`.
- Only a genuine bootstrap-check success without normal shell access should keep
  `nixos-rebuild` on the bootstrap user route.
- Script caches bootstrap readiness within one run.
- Script keeps per-host prepared deploy state in `PREP_*`, but host phases
  should materialize that state through the helper readers instead of accessing
  globals ad hoc.
- Bootstrap injection uses the configured operator identity to install key
  material to `/var/lib/nixbot/.ssh/id_ed25519` on the target.
- When replacing `/var/lib/nixbot/.ssh/id_ed25519`, bootstrap preserves the
  previous key at `/var/lib/nixbot/.ssh/id_ed25519_legacy`.
- On CI host, that path is also the deploy identity used for downstream host
  SSH; during rotation, use legacy key overrides until legacy hosts trust the
  new key.
- CI host nixbot SSH client should attempt both identities (`id_ed25519`, then
  `id_ed25519_legacy`) during overlap windows.
- Host age identity injection installs machine key material to
  `/var/lib/nixbot/.age/identity` before `nixos-rebuild` activation.

## Effective Deploy Sequence

1. Build host system closure.
2. Resolve bootstrap/primary SSH path, reset any stale prepared context, and
   prepare the deploy context.
3. Ensure target has deploy bootstrap key when needed
   (`/var/lib/nixbot/.ssh/id_ed25519`).
4. Inject host machine age identity from `hosts.<node>.ageIdentityKey` to
   `/var/lib/nixbot/.age/identity`.
5. Run `nixos-rebuild` on target.
6. agenix decrypts with
   `age.identityPaths = [ "/var/lib/nixbot/.age/identity" ]`.

## Script Structure Guidance

- Keep top-level flow phase-oriented:
  - parse args
  - optional `--ci-trigger`
  - optional TF phase
  - host orchestration
- Keep SSH option assembly centralized in helpers so primary and bootstrap paths
  share the same `known_hosts` and identity wiring rules.

## Machine Age Identity Rotation Policy

- Default: single-step replacement, no legacy overlap.
- Why: machine key is always injected just before activation.
- Overlap mode is optional and only needed for partial/out-of-band activations:
  - temporarily include both identities in `age.identityPaths`
  - encrypt host secrets to both recipients
  - remove legacy after migration.

## Validation Commands

- Forced-command help:
  - `ssh -i <ci-host-key> nixbot@<ci-host> -- --hosts <host> --help`
- Bootstrap check:
  - `ssh -i <ci-host-key> nixbot@<ci-host> -- check-bootstrap --hosts <host> --sha <commit> --config /var/lib/nixbot/nix/hosts/nixbot.nix`
- Local orchestrator:
  - `NIXBOT_CI_SSH_KEY_PATH=<...> nixbot deploy --hosts=<host> --force`

## Known Failure Signatures

- `Deploy config not found: hosts/nixbot.nix`
  - stale script path or missing explicit `--sha`/`--config` for forced-command
    call.
- `jq: command not found`
  - missing `jq` on CI host.
- `unknown option -- -`
  - missing `ssh ... -- <target> ...` separator.

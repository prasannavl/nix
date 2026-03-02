# Nixbot Deploy System (AI Reconstruction Spec)

## Goal

Reconstruct a secure deployment system where CI enters bastion using a
forced-command key, while regular `nixbot` SSH key behavior remains normal.

## High-Level Model

- CI -> bastion forced command -> build derivations -> deploy targets.
- Script tries `nixbot@target` first, then bootstrap fallback if needed.

## Security Invariants

- All hosts are on Tailscale.
- CI should have only:
  - Tailscale auth credential scoped to bastion reachability.
  - bastion ingress SSH key (forced-command only).
- Bastion ingress key must only run `/var/lib/nixbot/nixbot-deploy.sh`.
- Regular `nixbot` SSH key remains a normal key (defined in
  `lib/nixbot/default.nix`).
- Bastion stores private deploy key at `/var/lib/nixbot/.ssh/id_ed25519` (from
  `data/secrets/nixbot/nixbot.key.age`).
- Activation-time agenix decrypt uses machine identity
  `/var/lib/nixbot/.age/identity` (host specific), not the deploy SSH key.

## Bootstrap Definition

Bootstrap passes when:

1. `nixbot@host` ingress/fallback checks can be executed.
2. bootstrap key/decrypt material is available at expected paths.

If bootstrap fails, fallback uses configured bootstrap user/key path.

## Source Of Truth Files

- `scripts/nixbot-deploy.sh`
- `hosts/nixbot.nix`
- `lib/nixbot/default.nix`
- `lib/nixbot/bastion.nix`
- `users/userdata.nix`

## Bastion Module Requirements (`lib/nixbot/bastion.nix`)

- Add forced-command authorized key for `userdata.bastionSshKey`.
- Do not replace the normal `nixbot` key from `lib/nixbot/default.nix`.
- Install script to stable path:
  - `install -m 0755 ${../../scripts/nixbot-deploy.sh} /var/lib/nixbot/nixbot-deploy.sh`
- Ensure dependencies exist on bastion:
  - `age`, `jq`
- Ensure runtime SSH dir/permissions exist.
- Keep bastion deploy keys managed via `age.secrets.*` paths under
  `/var/lib/nixbot/.ssh`.

## Deploy Mapping (`hosts/nixbot.nix`)

Defaults:

- `user = "nixbot"`
- `key = "data/secrets/nixbot/nixbot.key.age"`

Optional per-host:

- `bootstrapKey`, `bootstrapUser`, `bootstrapKeyPath`, `knownHosts`
- `ageIdentityKey` (host machine age identity secret for activation-time
  decrypt)

Defaults may also include:

- `bootstrapKey`
- `bootstrapUser`

## Runtime Behavior Notes

- Forced-command bootstrap success does not guarantee generic shell access.
- Script may still fallback to bootstrap user for `nixos-rebuild --target-host`
  flow.
- Script caches bootstrap readiness within one run.
- Bootstrap injection installs key material to `/var/lib/nixbot/.ssh/id_ed25519`
  on the target.
- When replacing `/var/lib/nixbot/.ssh/id_ed25519`, bootstrap preserves the
  previous key at `/var/lib/nixbot/.ssh/id_ed25519_legacy`.
- On bastion, that path is also the deploy identity used for downstream host
  SSH; during rotation, use legacy key overrides until legacy hosts trust the
  new key.
- Bastion nixbot SSH client should attempt both identities (`id_ed25519`, then
  `id_ed25519_legacy`) during overlap windows.
- Host age identity injection installs machine key material to
  `/var/lib/nixbot/.age/identity` before `nixos-rebuild` activation.

## Effective Deploy Sequence

1. Build host system closure.
2. Resolve bootstrap/primary SSH path and prepare deploy context.
3. Ensure target has deploy bootstrap key when needed
   (`/var/lib/nixbot/.ssh/id_ed25519`).
4. Inject host machine age identity from `hosts.<node>.ageIdentityKey` to
   `/var/lib/nixbot/.age/identity`.
5. Run `nixos-rebuild` on target.
6. agenix decrypts with
   `age.identityPaths = [ "/var/lib/nixbot/.age/identity" ]`.

## Machine Age Identity Rotation Policy

- Default: single-step replacement, no legacy overlap.
- Why: machine key is always injected just before activation.
- Overlap mode is optional and only needed for partial/out-of-band activations:
  - temporarily include both identities in `age.identityPaths`
  - encrypt host secrets to both recipients
  - remove legacy after migration.

## Validation Commands

- Forced-command help:
  - `ssh -i <bastion-key> nixbot@<bastion> -- --hosts <host> --help`
- Bootstrap check:
  - `ssh -i <bastion-key> nixbot@<bastion> -- --hosts <host> --action check-bootstrap --sha <commit> --config /var/lib/nixbot/nix/hosts/nixbot.nix`
- Local orchestrator:
  - `DEPLOY_BASTION_SSH_KEY_PATH=<...> ./scripts/nixbot-deploy.sh --hosts=<host> --force`

## Known Failure Signatures

- `Deploy config not found: hosts/nixbot.nix`
  - stale script path or missing explicit `--sha`/`--config` for forced-command
    call.
- `jq: command not found`
  - missing `jq` on bastion.
- `unknown option -- -`
  - missing `ssh ... -- <target> ...` separator.

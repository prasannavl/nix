# Nixbot Deploy System (AI Reconstruction Spec)

## Goal
Reconstruct a secure deployment system where CI enters bastion using a forced-command key, while regular `nixbot` SSH key behavior remains normal.

## High-Level Model
- CI -> bastion forced command -> build derivations -> deploy targets.
- Script tries `nixbot@target` first, then bootstrap fallback if needed.

## Security Invariants
- All hosts are on Tailscale.
- CI should have only:
  - Tailscale auth credential scoped to bastion reachability.
  - bastion ingress SSH key (forced-command only).
- Bastion ingress key must only run `/var/lib/nixbot/nixbot-deploy.sh`.
- Regular `nixbot` SSH key remains a normal key (defined in `lib/nixbot/default.nix`).
- Bastion stores private deploy key at `/var/lib/nixbot/.ssh/id_ed25519` (from `data/secrets/nixbot.key.age`).
- Same key material is used for age-based secret decrypt workflows.

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
- Configure age identity bootstrap path:
  - `/var/lib/nixbot/.ssh/id_ed25519`

## Deploy Mapping (`hosts/nixbot.nix`)
Defaults:
- `user = "nixbot"`
- `key = "data/secrets/nixbot.key.age"`

Optional per-host:
- `bootstrapKey`, `bootstrapUser`, `bootstrapKeyPath`, `knownHosts`

Defaults may also include:
- `bootstrapKey`
- `bootstrapUser`

## Runtime Behavior Notes
- Forced-command bootstrap success does not guarantee generic shell access.
- Script may still fallback to bootstrap user for `nixos-rebuild --target-host` flow.
- Script caches bootstrap readiness within one run.
- Bootstrap injection installs key material to `/var/lib/nixbot/.ssh/id_ed25519` on the target.
- When replacing `/var/lib/nixbot/.ssh/id_ed25519`, bootstrap preserves the previous key at `/var/lib/nixbot/.ssh/id_ed25519_legacy`.
- On bastion, that path is also the deploy identity used for downstream host SSH; during rotation, use legacy key overrides until legacy hosts trust the new key.
- Bastion nixbot SSH client should attempt both identities (`id_ed25519`, then `id_ed25519_legacy`) during overlap windows.

## Validation Commands
- Forced-command help:
  - `ssh -i <bastion-key> nixbot@<bastion> -- --hosts <host> --help`
- Bootstrap check:
  - `ssh -i <bastion-key> nixbot@<bastion> -- --hosts <host> --action check-bootstrap --sha <commit> --config /var/lib/nixbot/nix/hosts/nixbot.nix`
- Local orchestrator:
  - `DEPLOY_BASTION_SSH_KEY_PATH=<...> ./scripts/nixbot-deploy.sh --hosts=<host> --force`

## Known Failure Signatures
- `Deploy config not found: hosts/nixbot.nix`
  - stale script path or missing explicit `--sha`/`--config` for forced-command call.
- `jq: command not found`
  - missing `jq` on bastion.
- `unknown option -- -`
  - missing `ssh ... -- <target> ...` separator.

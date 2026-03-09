# Nixbot Deploy System Consolidated Notes (2026-03)

## Scope

Canonical state for the March 2026 `nixbot` deploy system: bastion ingress,
bootstrap behavior, machine-age identity injection, forced-command handling,
remote-build host-key handling, and GitHub Actions connectivity.

## Stable architecture

- CI and local operators enter the bastion with a forced-command key only.
- The regular `nixbot` SSH key remains a normal shell/deploy key and is still
  defined through `lib/nixbot/default.nix`.
- `lib/nixbot/bastion.nix` adds only the forced-command authorized key and does
  not override the normal `nixbot` key setup.
- Activation-time `agenix` decrypt uses per-host machine identity at
  `/var/lib/nixbot/.age/identity`, not `/var/lib/nixbot/.ssh/id_ed25519`.

## Deploy flow

- `scripts/nixbot-deploy.sh` is the canonical entrypoint for both local
  orchestration and bastion-trigger execution via `--bastion-trigger`.
- Normal path is: resolve target -> prefer primary `nixbot@host` path -> fall
  back to bootstrap path when required.
- `--bootstrap` forces bootstrap target selection even if the primary path is
  reachable.
- When deploy user and bootstrap user are the same, bootstrap-key installation
  is cached per host for the duration of a run.
- Forced-command bootstrap probes execute `/var/lib/nixbot/nixbot-deploy.sh ...`
  explicitly so SSH does not hand option-like arguments to `bash`.

## Identity and secret handling

- `hosts/nixbot.nix` maps each host's activation identity with
  `hosts.<name>.ageIdentityKey = "data/secrets/machine/<host>.key.age"`.
- `scripts/nixbot-deploy.sh` injects that machine key to
  `/var/lib/nixbot/.age/identity` before activation.
- Bastion deploy keys stay as normal `age.secrets.*` material under
  `/var/lib/nixbot/.ssh`.
- When bootstrap replaces `/var/lib/nixbot/.ssh/id_ed25519`, the previous key is
  preserved as `/var/lib/nixbot/.ssh/id_ed25519_legacy`.
- Bastion-side SSH prefers the current key first and then the legacy key during
  overlap windows.

## Host-key and remote-build behavior

- The deploy script always uses strict host-key checking with dedicated
  temporary `known_hosts` files when it manages host keys itself.
- For `--bastion-trigger`, provided bastion known-hosts content is preferred;
  otherwise the script falls back to `ssh-keyscan -H <bastion-host>` and fails
  hard if no key material can be obtained.
- When `DEPLOY_BUILD_HOST` is distinct from the deploy target, that build host
  is also added to the temporary `known_hosts` file so `nix-copy-closure` and
  other SSH hops do not fail.
- For non-local remote builds, preflight records `toplevel.outPath` with
  `nix eval` and leaves realisation to `nixos-rebuild --build-host`.

## GitHub Actions state

- `.github/workflows/nixbot.yaml` now uses Tailscale OAuth/OIDC credentials
  instead of the deprecated auth-key input.
- Required workflow changes are:
  - `tailscale/github-action@v4`
  - `permissions.id-token: write`
  - `oauth-client-id`, `audience`, and `tags: tag:ci`
  - generated per-run hostname via `TS_HOSTNAME`

## Practical interpretation

- Bastion ingress is constrained to the deploy script.
- Shared deploy SSH keys and host-local age identities are separate concerns.
- Bootstrap behavior is explicit, cache-aware, and compatible with forced
  command entry.
- Remote builds and bastion-trigger runs now behave under the same strict host
  verification model as direct deploys.

## Superseded notes

- `docs/ai/notes/nixbot-bastion-key-model.md`
- `docs/ai/notes/nixbot-bastion-legacy-identity-retention.md`
- `docs/ai/notes/nixbot-bastion-manual-key-decrypt-activation.md`
- `docs/ai/notes/nixbot-deploy-bootstrap-flag.md`
- `docs/ai/notes/nixbot-deploy-flow-consolidated-2026-03.md`
- `docs/ai/notes/nixbot-forced-command-bootstrap-check-bash-dash-error.md`
- `docs/ai/notes/nixbot-github-actions-bastion-known-hosts-fallback-2026-03-09.md`
- `docs/ai/notes/nixbot-github-actions-tailscale-oauth-migration.md`
- `docs/ai/notes/nixbot-machine-age-identity-model.md`
- `docs/ai/notes/nixbot-remote-build-known-hosts-2026-03-09.md`

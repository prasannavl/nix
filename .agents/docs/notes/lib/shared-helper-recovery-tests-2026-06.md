# Shared Helper Recovery Tests (2026-06)

## Scope

Records the shared helper fixes ported from Abird into this repo in June 2026.
This note covers `lib/` behavior only; Abird-specific host declarations and
deployment incident notes stay in the Abird repo.

## Ported behavior

- `lib/profiles/incus-lxc.nix` keeps the LXC boot repair units boot-only with
  `restartIfChanged = false` and `stopIfChanged = false`, waits until
  `register-nix-paths.service` before replaying activation, then realigns
  `/nix/var/nix/profiles/system`, `/run/current-system`, and
  `/run/booted-system` to the guest-specific system path.
- `lib/podman-compose` keeps per-instance `timeoutStableSeconds = null` until
  stack normalization so stack defaults are not masked, and metadata loading
  uses `has("longRunning")` so explicit `false` survives jq parsing.
- `lib/services/stalwart` resolves mutable Stalwart IDs from stable data before
  apply: primary domains by name, directories by description, and network
  listeners by name. Declared directory IDs still win when they already exist
  live, so duplicate stale descriptions do not block a valid plan. Duplicate
  fallback matches are fatal instead of silently selecting the first row.
  Network listener update patches also strip `value.name` before
  `stalwart-cli apply` because Stalwart treats listener names as read-only on
  update.
- `lib/incus`, `lib/podman-compose`, `lib/profiles`, `lib/services/stalwart`,
  and `lib/systemd-user-manager` expose package/module regression tests through
  passthru or direct test imports.
- `pkgs/tools/data-migrator`, `host-manager`, `migrator`, and `nixbot` expose
  helper regression tests through package passthru. Keep these tests under each
  package's `tests/` directory so package-local conventional checks can run them
  without importing unrelated repo state.

## Port boundary

- Do not port Abird-only Stalwart listener declarations under
  `hosts/abird-corp/**` into this repo unless the target host exists here.
- Do not import Abird deployment incident notes into this repo. Use this note or
  a host-specific `pvl-*` note when the same shared helper behavior matters for
  PVL hosts.

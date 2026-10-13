# dotlink missing Go-module cache broke pvl-a1 activation

On 2026-10-13 a `fleet deploy --force --host=pvl-a1` failed at phase 4 (Deploy
systems): activation exited 4 because `dotlink.service` failed to start.

## Root cause

The pvl-a1/pvl-l5 `services.dotlink` module (see
[dotlink-pvl-a1-l5-2026-10](dotlink-pvl-a1-l5-2026-10.md)) enables
`cacheAccess."go-mod" = "rw"`, which renders `--allow-cache-go-mod=rw`. dotlink
v0.8.0 aborted startup when a requested developer-cache directory did not exist:

```text
dotlink[...]: Error: requested developer cache Go module was not found; create it first or use dotlink --setup
dotlink.service: Main process exited, code=exited, status=1/FAILURE
```

On pvl-a1 `/home/pvl/go/pkg/mod` does not exist (no Go builds have run there);
pvl-l5 has it, so pvl-l5's `dotlink.service` stayed active.
`switch-to-configuration` reports the failed unit and returns 4, so activation
aborts before promoting `/nix/var/nix/profiles/system`.

## Why rollback also failed

The fleet engine's rollback target is the phase-2 snapshot of
`readlink -f /run/current-system`. An earlier activation on the same host had
already left `/run/current-system` pointing at the candidate
`17p88…nixos-system-pvl-a1`, so the snapshot equalled the candidate and the
"rollback" re-activated the same broken generation. The last-known-good
booted/profile generation `wqybzdnr…` (dotlink 0.7.0) was not restored. This is
the sharp edge to watch: a snapshot taken after a prior failed switch is not a
last-known-good reference, and `--force` then re-deploys the candidate.

## Resolution

dotlink v0.8.1 (`e2eef9c fix(cache): skip missing caches at startup`) changes a
requested-but-absent cache to a startup warning; discovery only reports existing
directories, and the mount layer ignores absent sources. A cache created later
is picked up on the next restart. The repository input is bumped to v0.8.1, so
the `go-mod` grant no longer aborts and no manual `~/go/pkg/mod` creation is
required. The rollback-snapshot behaviour is a fleet-manager concern and is not
addressed by the dotlink bump.

## Observed state during the incident

- `/run/current-system` = candidate `17p88…`; `/etc` units = candidate.
- `/run/booted-system` and `/nix/var/nix/profiles/system` = `wqybzdnr…` (dotlink
  0.7.0). The bootloader was not updated, so a reboot returns to the working
  generation.
- `dotlink.service` in an `auto-restart` loop.

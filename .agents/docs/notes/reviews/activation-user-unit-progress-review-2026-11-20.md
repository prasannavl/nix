# Activation user-unit progress review

Scope: unstaged `abird-host-manager` deploy observer, presentation and fixture,
plus the implementation note; base `d62be79f4`. Source references below are
relative to `pkgs/tools/abird-host-manager/`.

## Findings

1. **P1 — Progress can delay or hang remote activation completion.**
   `src/fleet/deploy.rs:1046–1053,1080–1085` kills and waits for the background
   Bash function, not its descendants. A slow `list-jobs` kept the observer
   stream open for 4.975 s after the observer exited with a success marker; a
   blocked `getent` kept it open until the stub was released (`getent` has no
   timeout). The local Rust reader has an exit boundary, but remote `activate`
   waits on SSH, whose session still drains remote descriptors after shell exit.
   Give the entire sample, including account lookup, a hard deadline; ensure no
   monitor descendant can hold the observer's transport open when activation is
   done.
2. **P2 — `starting` can describe the stop half of a restart.**
   `src/fleet/deploy.rs:1058–1063` folds `restart` and `reload` into `start` and
   ignores the job state, so waiting jobs also read as work in progress.
   [systemd v260.5](https://github.com/systemd/systemd/blob/v260.5/src/core/job.c#L871-L883)
   runs `unit_stop` for `JOB_RESTART` and
   [changes the type to `JOB_START` only when the stop completes](https://github.com/systemd/systemd/blob/v260.5/src/core/job.c#L1024-L1035).
   [ListJobs returns the current type and state](https://github.com/systemd/systemd/blob/v260.5/src/core/dbus-manager.c#L1375-L1382).
   Preserve job types and label the count as pending. The existing fixture
   explicitly expects `restart` to be counted as `starting`.
3. **P2 — New test depends on ambient `getent`.** `tests/fleet_deploy.rs:666`
   discovers `getent` on `PATH`, yet `default.nix:32` does not declare
   `pkgs.getent` in `nativeCheckInputs`. With just the test's other tools on
   `PATH`, the test emitted no progress and failed; adding `getent` alone made
   it pass. Prefer a stub passwd entry for a deterministic fixture, or declare
   the real input.
4. **P3 — Sample loses the unit identity or drops useful counts.**
   `src/fleet/deploy.rs:1016–1021` rewrites valid `:` and repeated `-` in names
   (observed `app--blue:worker.service` → `app-blue-worker.service`). A 136-byte
   `.service` also reproduced a pre-existing validator limit exposed by this
   producer (`src/fleet/presentation.rs:1607–1609,1648–1654`): it drops the
   whole row. Preserve valid names verbatim; if a name cannot fit or be shown
   safely, omit it without discarding the count.

## Design

- `src/fleet/deploy.rs:1053,1120–1122` samples manager-wide jobs as soon as the
  log exists. A stub showed an unrelated timer while `Admitted=0`; terminal
  reattaches can also briefly start the sampler. Label this as a user-manager
  snapshot, not this switch's actions. No per-activation job tracking or state
  inference needed. Skip polls that cannot be useful.
- Keep observer completion independent of bounded telemetry. If retaining
  `[user-units]` and `[system-units]`, parse their common `action/count/units`
  fields once and render separately.

## Validation

- A deterministic fixture should block and release a query, drive samples past
  the throttle window, and cover an empty-to-nonempty transition. The current
  short, steady fixture does not deliberately cross the window. A controlled
  sample with the same job before and after an empty queue emitted only once;
  the signature survives an empty sample.
- `cargo test -p abird-host-manager --locked --offline -j 1 --lib fleet::presentation::tests`
  (24/24), and
  `cargo test -p abird-host-manager --locked --offline -j 1 --test fleet_deploy`
  (36/36) passed with the workstation environment. `git diff --check` passed.
- Local fixtures ran the current observer shell with stub manager, NSS and log
  follower. No live deployment, remote test, fleet/system build or full Nix
  check; the SSH impact follows the upstream session/EOF contract.

## Follow-up

The sampler owns a Bash job process group. Observer exit, cancellation, and a
query timeout all terminate that group, without changing activation. The timeout
regression failed before the fix with activation still running. Tests cover
blocked descendants, direct TERM during startup and sampling, and prompt EOF on
both streams.

`[user-jobs]` reports manager-wide pending jobs by their actual job type. Exact
unit names are kept when they fit; no sample is required to show the count. A
fixed passwd fixture removes ambient `getent` dependence. Tests also cover
terminal reattachment and deduplication across empty snapshots.

Scoped Nix formatting, Clippy and package tests passed (1,172 passed, 3 existing
ignores). Seven observer tests passed in five consecutive runs. No live
deployment or full-monorepo `nix flake check`.

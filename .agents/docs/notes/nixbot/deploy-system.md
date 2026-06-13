# Nixbot Deploy System

## Scope

Canonical durable state for `pkgs/tools/nixbot/nixbot.sh`: entrypoint and
packaging, SSH and bootstrap behavior, identity and secret injection, worktree
and locking rules, Terraform dispatch, and operator trust boundaries.

## Entrypoint and packaging

- `pkgs/tools/nixbot/nixbot.sh` is the canonical script source.
- `scripts/nixbot.sh` is only a thin compatibility wrapper that `exec`s into the
  package-owned entrypoint.
- Child-flake and package wiring should execute the packaged script with the
  full runtime toolchain already present and set `NIXBOT_IN_NIX_SHELL=1`.
- `run` is the explicit full-workflow entrypoint. Other top-level actions stay
  first-class modes: deploy, build, local dev-build, Terraform phases,
  dependency checks, and bootstrap checks.
- `--hosts` accepts exact host names, comma/space-separated host lists, `all`,
  shell-style globs, and `-`-prefixed exact or glob exclusions such as
  `all,-pvl-a1`. A selector list containing only exclusions means all hosts
  except those exclusions. Glob expansion and exclusions happen against the
  NixOS configuration names before normal dependency expansion and ordering.
- `dev-build` is local-only. It runs from the current checkout instead of the
  managed repo worktree, rejects `--sha` and `--ci-trigger`, and writes
  `result-dev/<host>` links in the repo root as temporary GC roots. Clearing
  those roots is `rm -rf result-dev`.

## Core architecture

- `nixbot` is the only supported orchestration entrypoint for local, CI, and CI
  host-triggered runs.
- The deploy system separates:
  - SSH deploy identity
  - per-host machine age identity
  - CI host forced-command ingress identity
- Worktree isolation is for concurrency and checkout safety, not for reducing
  operator trust.

## Connectivity and bootstrap model

- Normal targeting prefers `nixbot@host`. Bootstrap is a fallback path unless
  explicitly forced.
- CI host-triggered runs may flatten leading self-targeting proxy hops, but they
  must retry the full configured proxy chain before falling back to bootstrap.
- Self-target deploys should execute locally only when the current runtime user
  is already the deploy user. Local operator runs should preserve the normal
  `nixbot` SSH trust boundary.
- Generated proxy wrappers must preserve per-hop SSH users and identity files
  and emit IPv6-safe forwarding targets.
- Host config may use `proxyCommand` for explicit transports such as Cloudflare
  Access. Proxy command templates support `%h` and `%p`, compose with
  `proxyJump`, and use generated wrapper scripts so nixbot can keep SSH config
  and known-hosts isolation intact.
- SSH control-master reuse is acceptable for direct primary and bootstrap
  contexts, but stale control sockets must be cleared when readiness or
  bootstrap state changes.
- `nixbot` SSH invocations must ignore ambient operator SSH config by passing
  `-F /dev/null`. Repo deploy targets must not depend on local aliases.

## Bootstrap and identity injection

- Preserve the prepared SSH identity during forced-command bootstrap checks
  unless an explicit override key is configured.
- After bootstrap key installation, immediately re-probe and promote back to the
  primary `nixbot@host` path when it becomes available.
- If a local-build deploy would still target a non-`nixbot`, non-`root`
  bootstrap user, retry primary-route promotion during parent-settle preparation
  and still fail before `nixos-rebuild` instead of letting remote closure import
  fail later.
- Host age identity injection is a standard pre-activation step. The runtime
  path must be readable by `nixbot`, not only by root.
- Prepare host age identity material once per host and reuse the resolved file
  and checksum across prechecks, injection, and activation-context validation.
- Activation-context visibility probes must use explicit
  `/run/current-system/sw/bin` paths inside transient units.

## Runtime workspace and locking

- Each run should allocate paired runtime and diagnostic directories with the
  same id:
  - runtime: `/dev/shm/nixbot/run-XXXXXX`
  - diagnostics: `/dev/shm/nixbot/diag-XXXXXX`
  - if `/dev/shm` is unavailable, both fall back under `${TMPDIR:-/tmp}/nixbot`
- Runtime contains the detached repo worktree, decrypted secrets, SSH control
  sockets, Terraform plans, self-target temp files, build result symlinks, build
  output path files, rollback snapshots, and phase artifacts.
- Diagnostics contains logs, status files, and stderr captures. It must stay
  safe to retain directly without a cleanup or sanitization pass.
- Parallel remote builds prewarm the build-host SSH ControlMaster before fanout
  so per-host builds reuse the same socket instead of racing to create it.
- Remote builds use `--eval-store auto` with `--store ssh-ng://<build-host>`.
  Evaluation should stay local while realization happens on the build host;
  otherwise Nix can spend minutes materializing evaluation inputs through the
  remote store before the build host has CPU-heavy derivation work.
- Remote deploy builds default to `--build-host-deploy-mode cache`: verify the
  build-host cache, make the target copy the exact path from that cache, then
  activate it. `--build-host-deploy-mode local-copy` instead copies the signed
  closure back to the local store and pushes that exact local store path to the
  target before activation. Use `local-copy` when the operator can reach both
  sides but the target cannot reach the build-host cache.
- Only the `nixbot` account is added as a trusted Nix user. Direct runs from an
  untrusted operator account can still warn that the client-specified `store`
  setting is restricted; avoid broad trust expansion and run through `nixbot`
  when the warning must be eliminated.
- Quiet remote builds emit a low-noise heartbeat every
  `NIXBOT_BUILD_HEARTBEAT_SECS` seconds, defaulting to 30. Set it to `0` to
  disable. `--build-logs` / `NIXBOT_BUILD_LOGS=1` additionally passes `-L` to
  `nix build` when actual builder logs are desired. Heartbeat workers must close
  stdout because remote builds are captured through command substitution; if a
  heartbeat inherits that pipe, the wrapper can appear stuck after Nix exits.
- Successful runs remove both runtime and diagnostic directories. Failed,
  interrupted, or hung-up runs always remove runtime and retain diagnostics by
  moving `diag-XXXXXX` to `/var/tmp/nixbot/diag-XXXXXX` when the run used
  `/dev/shm`.
- Interrupt cleanup terminates registered background jobs, SSH control masters,
  and same-process-group nixbot wrapper processes. The wrapper cleanup is
  guarded so it only runs when nixbot has a distinct process group from its
  parent.
- Managed repo locking must cover the first clone path as well as steady-state
  repo refreshes.
- Repo-root locks must recover from stale owners rather than spinning forever.
- `--dirty-staged` overlays must fail closed if the cached diff cannot be
  applied cleanly.
- Nixbot evaluates the selected config file and recursively overlays a
  gitignored sibling local config when that file exists. The local path is
  derived by replacing the final `.nix` suffix with `.override.nix`, so
  `hosts/nixbot.nix` can be overridden by `hosts/nixbot.override.nix`. The local
  file should contain only partial machine-local overrides. Use `--no-override`
  to evaluate the selected config alone.
- Agent-run deploys should prefer `--no-rollback` during diagnosis so failed
  state remains inspectable. Finish with a fully successful deploy, or perform a
  deliberate rollback after the root cause is understood.
- Record per-host deploy duration when investigating deploy regressions. A
  sudden slowdown is a signal to inspect recent service or health-check changes
  before increasing timeout budgets.

## SSH transport rules

- Keep stdout and stderr separate for machine-readable remote helpers.
- Critical remote helpers should treat `/run/current-system/sw/bin` as the
  runtime contract instead of relying on ambient PATH.
- Safe idempotent remote operations may use bounded transport retries. Mutating
  steps should remain intentionally narrower to avoid duplicate side effects.
- Remote file installation should retry transport failures for temp allocation,
  copy, and install execution.
- Any future interactive remote sudo path must serialize TTY-owning SSH calls
  and restore the operator TTY state after each call and at cleanup.

## Deploy orchestration

- Host `skip = true` is a full orchestration exclusion. Such hosts may match a
  selector, but they are omitted from the runnable host banner and final summary
  and are not built, snapshotted, deployed, or health-checked.
- Host `deploy = "skip"` is narrower: the host stays buildable/evaluable, but
  nixbot must not touch the live target. Rollback snapshots and deploy/switch
  work are skipped because no activation can require rollback.
- Snapshot work and deploy work both use the deploy parallelism budget within a
  dependency wave.
- Deploy parallelism defaults to 16 jobs per dependency wave. Rollback-snapshot
  and post-switch health-check work use a separate verify parallelism budget
  controlled by `--verify-jobs` / `NIXBOT_VERIFY_JOBS`, also defaulting to 16.
- Parallel host builds disable Nix's flake eval cache for per-host build and
  output-path evaluation commands to avoid SQLite cache contention.
- Before switching a host generation, deploy clears stale system-unit failed
  state and failed unit state for active managed user managers. The post-switch
  health check should fail the deploy on new system-unit failures, including
  Home Manager activation units, so self-target transport recovery cannot turn a
  partially failed switch into success just because `/run/current-system` points
  at the new generation. User-service failures should still be scoped to the
  deploy window, not stale display-session failures left behind by earlier
  compositor logout/login churn.
- Post-switch health checks ignore transient failed Podman healthcheck runner
  units and instead query current Podman container health. The health check
  still fails immediately on ordinary failed system/user units and on Podman
  containers whose current health is `unhealthy`; containers still in `starting`
  are polled for a bounded window so healthcheck intervals do not trigger
  premature rollback. The wait budget comes from the maximum generated
  `systemd-user-manager` `timeoutStableSeconds` metadata on the host, so service
  modules own convergence policy instead of nixbot carrying a separate service
  timeout. If starting containers are present but no service-owned timeout
  metadata exists, the health check fails rather than inventing an unmanaged
  wait budget. Health-check failures are tracked separately in the final summary
  and roll back using health-specific rollback status buckets.
- Post-switch health checks require primary `nixbot@host` transport and use the
  parent-settle transport-preparation retry plus bounded SSH transport retry, so
  nested hosts that briefly close SSH during parent or guest reactivation do not
  get marked unhealthy before the service checks actually run. Health checks
  clear cached primary readiness for parented hosts before probing, because a
  pre-switch primary-ready cache entry or ControlMaster can be stale after
  parent and guest activation. Bootstrap fallback is for repair/deploy
  preparation, not steady-state health verdicts.
- Remote `nixos-rebuild-ng` deploys that lose SSH with exit `255` after a
  network-disrupting switch verify the target system path before being treated
  as failed. This mirrors the self-target deploy guard without masking ordinary
  non-transport activation failures.
- Remote build-host store operations must use the same bounded transport retry
  policy. `nix build --store ssh-ng://...` can wrap an SSH timeout as a generic
  Nix failure instead of returning SSH's exit code 255, so retry classification
  must inspect the Nix stderr text for transport failures.
- Deploys with non-local `--build-host` require a configured builder cache in
  `hosts/nixbot.nix`. The builder's Nix daemon signs locally built paths through
  host-side `nix.settings.secret-key-files`; local `nixbot` verifies the path is
  visible through the builder cache, the target pulls that path from the cache,
  and local `nixbot` activates that exact path over the prepared target SSH
  context.
- Cache-pull transport to the target uses the prepared target transport retry
  path, while activation itself remains a single mutating operation. `nixbot`
  must not take ownership of builder signing commands.
- Dry deploys may still evaluate and build systems, but prepared target commands
  must be printed instead of executed. This includes parent readiness
  reconcile/settle commands; do not let `--dry` run parent-side Incus
  reconciliation.
- Parent-host readiness failures must propagate real command failures; do not
  swallow exit status through Bash `if` compound semantics.
- Host selection and helper naming should keep classification side-effect free:
  `prepare_*` for setup, `resolve_*` or `evaluate_*` for classification.
- Avoid scalar `local -n` output helpers when stdout capture or shared prepared
  context is simpler and safer.

## Interrupt Handling

- `SIGHUP` is an incidental caller disconnect. Local cleanup should run; this
  cancels local deploy work that has not reached the switch submission yet, and
  any activation that `nixos-rebuild-ng` has already submitted through
  `systemd-run` should be left to complete.
- Ctrl-C and `SIGTERM` are explicit cancellation requests. If no remote deploy
  activation is active yet, nixbot should clean up local jobs and exit
  immediately.
- The first Ctrl-C or `SIGTERM` while remote deploy activation is active should
  stop scheduling new deploy work, wait for already-started deploy jobs to
  finish, then exit.
- Three consecutive Ctrl-C or `SIGTERM` signals within 3 seconds should make a
  best-effort attempt to stop `nixos-rebuild-ng`'s fixed
  `nixos-rebuild-switch-to-configuration.service` only on hosts currently inside
  the `nixos-rebuild-ng` deploy command or its transport-loss verification
  window, wait for cancellation, then send `SIGKILL` after the remote
  cancellation grace period.
- Serial and parallel deploys should both run host deploy work through the same
  supervised background-job path so cancellation behavior does not depend on
  `--deploy-jobs`.
- Self-target SSH deploys should use the same `nixos-rebuild-ng` path as other
  remote deploys. `nixos-rebuild-ng` already wraps activation in `systemd-run`
  on systemd hosts, so nixbot should not add a second activation unit layer
  unless it needs per-run remote status ownership later.
- Cancellation cleanup should terminate local host-job process trees, then
  escalate to `SIGKILL` after a short grace window.
- Active deploy tracking should be file-backed and keyed by a
  collision-resistant digest of the host name, with the host name stored as file
  contents for remote cancellation commands.
- Cleanup should also terminate persistent SSH control-master processes rooted
  in the run-local SSH directory, because those can outlive the shell job that
  created them.

## Terraform dispatch

- `tf`, `tf-dns`, `tf-platform`, `tf-apps`, and `tf/<project>` should bypass
  host orchestration setup and go straight to the Terraform flow.
- Runtime secret loading should use the shared age-identity candidate list, not
  provider-specific special cases.
- Fresh worktrees expose stale Terraform lockfile state immediately, so deploy
  automation should keep `-lockfile=readonly` and fix lockfiles rather than
  mutating them during deploy.

## CI and CI host trigger model

- The GitHub Actions workflow is a thin launcher that warms the local runner,
  runs lint, and triggers the CI-hosted deploy flow.
- The CI host owns the persistent repo, store, and worktree state.
- CI host-triggered forwarding should use encoded argv transport. Legacy raw
  `SSH_ORIGINAL_COMMAND` parsing remains only as a narrow compatibility path.
- CI host-triggered operators are trusted deploy operators. If tighter SHA or
  ref policy is needed later, enforce it explicitly.

## Key rotation

- Overlap rotation is the default for SSH deploy keys.
- Keep design memory in `.agents/docs/notes/nixbot/key-rotation.md` and the
  step-by-step execution in the key-rotation playbooks.

## Source of truth files

- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/default.nix`
- `pkgs/tools/nixbot/flake.nix`
- `scripts/nixbot.sh`
- `hosts/nixbot.nix`
- `lib/nixbot/default.nix`
- `lib/nixbot/ci.nix`
- `.github/workflows/nixbot.yaml`

## Provenance

- This note replaces the earlier dated deploy, bootstrap, SSH, locking,
  Terraform, and review-followup notes from March and April 2026.

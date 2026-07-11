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
- `pkgs/tools/nixbot/nixos-module.nix` owns the NixOS service integration:
  primary `nixbot` user, trusted-user wiring, sudo policy, age identity paths,
  state directories, optional CLI exposure, outbound SSH client config, and
  repo-specific forced-command ingress.
- Host common modules own policy:
  - `hosts/common/all.nix` enables `services.nixbot` by default and sets normal
    deploy/login authorized keys.
  - CI host common modules add `services.nixbot.repos.<name>` entries plus
    `age.secrets` for the deploy SSH identities used by outbound Git and host
    deploy SSH.
- `users/userdata.nix` carries identity metadata for humans and automation.
  `nixbot.sshKeys` and `nixbot.ciSshKeys` are the single public-key source for
  deploy trust, CI ingress trust, and secret recipients.
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
- Interactive host log output may normalize high-volume activation, closure
  copy, agenix, unit-action, and health-check rows for readability. Persisted
  per-host logs keep the raw unnormalized output, and GitHub log mode bypasses
  the interactive formatter.
- Parallel remote builds prewarm the build-host SSH ControlMaster before fanout
  so per-host builds reuse the same socket instead of racing to create it.
- Remote builds use `--eval-store auto` with `--store ssh-ng://<build-host>`.
  Evaluation should stay local while realization happens on the build host;
  otherwise Nix can spend minutes materializing evaluation inputs through the
  remote store before the build host has CPU-heavy derivation work.
- Remote deploy builds default to `--build-host-deploy-mode auto`: use `cache`
  when `--build-host` resolves to the configured `globals.buildCache.host`;
  otherwise use `local-copy`. `cache` verifies the build-host cache, makes the
  target copy the exact path from that cache, then activates it. `local-copy`
  verifies the same signed cache path, then relays it from the build-host cache
  to the target with the local client and the same temporary target trust-key
  bridge. Deploy local-copy mode intentionally avoids raw `ssh-ng://` copy-back
  into the operator store. Build-only copy-back uses the signed build-host cache
  when it is configured, and falls back to raw `ssh-ng://` only when there is no
  cache. Use `local-copy` when the operator can reach both sides but the target
  cannot reach the build-host cache.
- Build-cache config validation is fail-fast and specific: missing URL, missing
  host, and selected-build-host/cache-owner mismatches should each produce a
  distinct pre-activation error.
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
- Long-running remote-store commands must be supervised as background jobs with
  stdout captured to an explicit temp file. Do not wrap
  `nix build --store
  ssh-ng://...` directly in command substitution: Bash
  defers the parent trap while waiting for that foreground capture, so Ctrl-C
  can interrupt Nix but leave nixbot's heartbeat/retry wrapper alive.
- Long-running commands that capture stdout, including local builds, dev builds,
  remote builds, and transport checks, should use the shared supervised capture
  runner. Do not add new command-substitution wrappers around `nix`, `ssh`,
  `tofu`, or other potentially long-running commands; the runner owns the child
  process tree, temp stdout capture, optional stderr tee, and signal-status
  restoration.
- Host-local remote scripts should be modeled as `_remote_*` Bash functions and
  emitted through the shared remote-function command builder. Avoid adding new
  large inline heredoc command bodies unless the payload is data, not reusable
  remote behavior; tests should at least parse generated remote snippets with
  `bash -n`.
- Retry loops must test `is_signal_exit_status` before transport retry,
  parent-readiness retry, or post-failure verification. `130` and `143` are
  control flow, not ordinary operation failures.
- Operator-visible local wait and polling loops should use
  `sleep_for_retry_or_signal` so Ctrl-C cannot be consumed as a transient wait
  failure. Deliberate cleanup grace sleeps and remote-side helper sleeps are
  separate contracts.
- Successful runs remove both runtime and diagnostic directories. Failed,
  interrupted, or hung-up runs always remove runtime and retain diagnostics only
  when the diagnostic tree contains actual files, moving non-empty `diag-XXXXXX`
  to `/var/tmp/nixbot/diag-XXXXXX` when the run used `/dev/shm`. Empty
  diagnostic scaffolding must be removed instead of leaving empty `/dev/shm` or
  `/var/tmp` directories behind.
- EXIT cleanup runs through a trap-specific wrapper over a best-effort cleanup
  core. Individual cleanup helpers may fail without skipping runtime removal,
  while direct cleanup callers keep their original `errexit` state.
- `nixbot clean` and `nixbot --clean[=auto|all]` are local cleanup actions.
  `auto` removes stale `/dev/shm/nixbot` and `/var/tmp/nixbot` run/diagnostic
  directories older than one day; `all` removes those roots entirely.
  `--clean --ci-trigger` forwards the same hostless cleanup request to the CI
  host and does not accept `--dirty-staged`.
- `nixbot clear-remote-locks` and
  `nixbot --clear-remote-locks[=all|nixbot|podman]` remove only repo-managed
  remote lock paths for the selected hosts. The `nixbot` mode clears nixbot
  runtime, SSH TTY, and managed worktree locks; the `podman` mode clears
  declared Podman Compose lifecycle lock files plus rootless lifecycle lock
  files under `/run/user`; `all` clears both. `--dry` audits held lock owners on
  the selected hosts without unlinking files. `--force` also unlinks held lock
  files after reporting holders.
- Interrupt cleanup terminates registered background jobs, SSH control masters,
  and same-process-group nixbot wrapper processes. The wrapper cleanup is
  guarded so it only runs when nixbot has a distinct process group from its
  parent.
- Managed repo locking must cover the first clone path as well as steady-state
  repo refreshes.
- Repo-root locks must recover from stale owners rather than spinning forever.
- `--skip-global-lock` / `NIXBOT_SKIP_GLOBAL_LOCK=1` skips only the
  operator-machine host-local action mutex for manual overlapping nixbot runs.
  It does not bypass deploy activation locks, rollback locks, or target-host
  systemd serialization.
- `--dirty-staged` overlays must fail closed if the cached diff cannot be
  applied cleanly. Local runs generate the overlay from the staged index; CI
  host-triggered runs send a binary staged patch over SSH stdin and require the
  remote detached worktree to be at the matching base commit. Unstaged tracked
  and untracked files are intentionally ignored. If there are no staged changes,
  the overlay is a no-op and the run continues from committed state.
- Nixbot evaluates the selected config file and recursively overlays a
  gitignored sibling local config when that file exists. The local path is
  derived by replacing the final `.nix` suffix with `.override.nix`, so
  `hosts/nixbot.nix` can be overridden by `hosts/nixbot.override.nix`. The local
  file should contain only partial machine-local overrides. Use `--no-override`
  to evaluate the selected config alone.
- `--ci-trigger` uses the checked-in config boundary on both sides: the remote
  request includes `--no-override`, and local discovery of `globals.ci.host`
  also ignores sibling `*.override.nix` files.
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
- Snapshot work, deploy work, and rollback execution use the deploy parallelism
  budget within a dependency wave. Rollback execution walks dependency levels in
  reverse, so child/dependent hosts roll back before parents while hosts inside
  each rollback level can still fan out up to the deploy job limit.
- Deploy parallelism defaults to 8 jobs per dependency wave. Rollback-snapshot
  and post-switch health-check work use a separate verify parallelism budget
  controlled by `--verify-jobs` / `NIXBOT_VERIFY_JOBS`, also defaulting to 16.
- `--no-verify` / `NIXBOT_NO_VERIFY=1` skips post-switch health checks only. It
  does not disable rollback snapshots while rollback remains enabled, so deploy
  failures can still roll back to the recorded pre-deploy generation.
- When rollback snapshots are enabled and `--force` is not set, snapshot result
  processing compares the recorded current generation to the built target
  generation. Matching hosts are recorded as deploy skips and are not scheduled
  into the deploy wave, so no switch preparation, activation, health check, or
  rollback is attempted for that no-op host. The per-host skip line is emitted
  through host log prefixing as `skip deploy: gen up-to-date`. If a deploy wave
  has no remaining changed hosts after this filtering, the deploy phase prints
  `Skipping: No changed hosts`.
- Parallel deploy waves fail fast after the first required host deploy failure:
  `nixbot` stops scheduling new hosts, terminates sibling deploy jobs that have
  not reached `switch-to-configuration`, and leaves sibling hosts that have
  already submitted activation to finish. Pre-activation siblings canceled this
  way remain built-only in the final summary rather than becoming independent
  deploy failures. Completed failed-host rollbacks and subsequent unwind
  rollbacks share the same deploy parallelism budget.
- Before activation, deploy jobs run the built target system's Podman Compose
  image-pull plan after the Nix closure has been copied to the target and before
  `switch-to-configuration` is submitted. The plan lives at
  `<system>/share/podman-compose/image-pulls.json` and is executed through
  `<system>/sw/bin/podman-compose-image-pull-all`. The plan is generated from
  compose-backed service metadata, so it does not require a separate host-local
  `imageTag` marker for deploy-time image pulls. This keeps remote image fetches
  out of activation and out of managed service start, while preserving the
  existing pre-activation cancellation behavior if a required host fails.
- Host builds first evaluate selected NixOS toplevel derivation paths through
  the host-scoped flake output `nixbot.plans.${host}.drvPath`. The build-plan
  phase checks a persistent source-snapshot cache, evaluates cache misses with
  bounded parallelism from `--build-plan-jobs` / `NIXBOT_BUILD_PLAN_JOBS`
  (default `auto`, calculated as online CPU threads divided by 2 plus 1), and
  writes the resulting per-host `.drv` paths into the run-local build-plan
  directory. The phase prints an immediate total duration after all selected
  hosts have a plan. Cache keys use `HEAD` plus `git write-tree`, so normal
  clean runs and `--dirty-staged` snapshots share the same source-identity
  model. The cache context is computed once in the parent before parallel
  fanout; host workers must not run Git index refreshes, because parallel
  `git update-index` attempts can contend on `.git/**/index.lock`. Plain
  unstaged `--dirty` runs skip the persistent cache because unstaged file
  contents are not represented by the index tree. If `nixbot.plans` is
  unavailable, the plan phase falls back to the compatible
  `nixosConfigurations.${host}.config.system.build.toplevel.drvPath` attr path.
  Per-host cache-miss progress is intentionally compact: the per-host prefix
  identifies the host, so the message body should stay `Evaluating..` instead of
  repeating the host name.
- Per-host build jobs then realize the precomputed `.drv^out` installable,
  preserving existing per-host logs, status files, result links, and
  remote/local build modes without re-evaluating host flake attributes. The
  overall build phase prints an immediate total duration after build jobs
  finish. Remote build-host jobs explicitly copy the planned derivation closure
  to the build-host store before realization so `--build-host` does not depend
  on per-host flake installable evaluation.
- Parallel build-plan workers disable Nix's SQLite flake eval cache to avoid
  contention; nixbot's persistent clean-worktree build-plan cache is the repeat
  run cache for this phase. Sequential build-plan evals can still use Nix's eval
  cache.
- Parallel host builds still disable Nix's flake eval cache for the per-host
  build commands to avoid SQLite cache contention; those commands should already
  consume build-plan `.drv^out` installables instead of host flake attributes.
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
  `systemd-user-manager` `timeoutReadySeconds` metadata on the host, so service
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
- Remote `nixos-rebuild` deploys that lose SSH with exit `255` after a
  network-disrupting switch verify the target system path before being treated
  as failed. This mirrors the self-target deploy guard without masking ordinary
  non-transport activation failures.
- Remote build-host store operations must use the same bounded transport retry
  policy. `nix build --store ssh-ng://...` can wrap an SSH timeout as a generic
  Nix failure instead of returning SSH's exit code 255, so retry classification
  must inspect the Nix stderr text for transport failures such as broken pipes
  or bad file descriptors.
- Deploys with non-local `--build-host` require a configured builder cache in
  `hosts/nixbot.nix`. The builder's Nix daemon signs locally built paths through
  host-side `nix.settings.secret-key-files`; local `nixbot` verifies the path is
  visible through the builder cache, the target pulls that path from the cache,
  and local `nixbot` activates that exact path over the prepared target SSH
  context.
- Cache-pull transport to the target uses the prepared target transport retry
  path, while activation itself remains a single mutating operation. `nixbot`
  must not take ownership of builder signing commands.
- Direct store-path activation intentionally uses promote-after-success ordering
  for `switch` and `boot`: first run the target's `bin/switch-to-configuration`,
  then set `/nix/var/nix/profiles/system` to the target system with
  `nix-env --set` only if activation succeeds. This differs from
  `nixos-rebuild switch` and makes failed activation avoid promoting the system
  profile. Bare-metal hosts may run bootloader work during activation; hosts
  whose evaluated `config.boot.isContainer` is true must keep
  `NIXOS_INSTALL_BOOTLOADER=0`. For promote-after-success `switch`, the first
  activation must also keep `NIXOS_INSTALL_BOOTLOADER=0`; after profile
  promotion succeeds, bare-metal hosts run a separate
  `switch-to-configuration boot` so boot entries are generated from the promoted
  system profile.
- Transient activation scripts must be transported as single-line,
  POSIX-shell-safe commands, not as `bash -lc $'...'` multiline payloads. Decode
  the script inside the transient unit and run it with non-login Bash so
  `/etc/bash_logout` cannot inherit activation `set -u`. Because that runner is
  non-login, activation scripts must use explicit tool paths instead of relying
  on ambient `PATH`; post-activation profile promotion should use the target
  system's own `sw/bin/nix-env`.
- Boolean host classification evals must use `nix eval --json`, not `--raw`.
  Rollback snapshot files are data inputs: before rollback activation they must
  resolve to exactly one NixOS system store path, even if surrounding warning
  text was captured from a previous command.
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
  any activation that `nixos-rebuild` has already submitted through
  `systemd-run` should be left to complete.
- Ctrl-C and `SIGTERM` are explicit cancellation requests. If no remote deploy
  activation is active yet, nixbot should clean up local jobs and exit
  immediately.
- Remote-store builds must own an interrupt trap inside the host-job shell that
  starts the background `nix build` and heartbeat. It is not enough for the
  top-level nixbot process to have a trap: Bash can defer a parent trap while it
  waits on a foreground host-job subshell, and a child shell without its own
  trap can keep printing remote-build heartbeats after Nix itself has already
  received Ctrl-C. The remote-store wrapper should treat `SIGINT`/`SIGTERM` as a
  first-class result, kill its heartbeat and command tree, and return the signal
  status without transport retries.
- Captured long-running commands must use the shared supervised runner instead
  of command substitution. This keeps the trap in the waiting shell, terminates
  the command process tree, restores the previous trap state, and propagates the
  signal exit code to callers.
- The first Ctrl-C or `SIGTERM` while remote deploy activation is active should
  stop scheduling new deploy work, wait for already-started deploy jobs to
  finish, then exit.
- Three consecutive Ctrl-C or `SIGTERM` signals within 3 seconds should make a
  best-effort attempt to stop `nixos-rebuild`'s fixed
  `nixos-rebuild-switch-to-configuration.service` only on hosts currently inside
  the `nixos-rebuild` deploy command or its transport-loss verification window,
  wait for cancellation, then send `SIGKILL` after the remote cancellation grace
  period.
- Serial and parallel deploys should both run host deploy work through the same
  supervised background-job path so cancellation behavior does not depend on
  `--deploy-jobs`.
- Target activation and rollback use per-run transient units for remote status
  ownership and bounded lifetime, but `switch-to-configuration` itself owns
  same-host activation serialization through
  `/run/nixos/switch-to-configuration.lock`. Nixbot must not wrap activation in
  its own persistent lock. If that native lock reports contention, nixbot should
  fail the deploy and print current nixbot activation/rollback units plus recent
  `switch-to-configuration` journal context.
- Cancellation cleanup should terminate local host-job process trees, then
  escalate to `SIGKILL` after a short grace window.
- Active deploy tracking should be file-backed and keyed by a
  collision-resistant digest of the host name, with the host name stored as file
  contents for remote cancellation commands.
- Cleanup should also terminate persistent SSH control-master processes rooted
  in the run-local SSH directory, because those can outlive the shell job that
  created them.
- Parent readiness output is summarized on the successful path: each parent
  group prints one `ok (Ns)` line after reconcile and settle complete. Slow
  successful phases and failures expand with phase, resource list, and timing.
- ANSI color is applied to per-host stage headers, log-line prefixes, and the
  run summary when stderr is a TTY and not in GitHub Actions log mode. Each host
  receives a stable palette color derived from an FNV-1a hash of its name for
  stage output, so the same host always uses the same color across runs.
  Rollback phase headers and prefixes use gray for all hosts so rollback output
  is visually distinct from deploy. In the summary, host names are not
  palette-colored: plain successful `ok` statuses are green, skipped and
  rolled-back host lines are gray, failed host lines are red, and optional
  failure/rollback lines are mild yellow. Terminal output may be colored, but
  persisted per-host diagnostic logs stay plain text. Set `NO_COLOR=1` to
  disable; set `NIXBOT_FORCE_COLOR=1` to force on (overrides `NO_COLOR`). Color
  is automatically suppressed in `gh`/`github-actions` log format.
- Host log prefixes are applied at stream boundaries. Helpers that may run
  inside an already-prefixed stream should emit raw lines through
  `host_log_filter`; the active prefix context suppresses redundant nested
  prefixes instead of cleaning them up after formatting. Prefixing also runs the
  compact console formatter first, so repeated Nix build lines such as
  `building '/nix/store/...drv'...` show as short `[build] <drv>` rows before
  the host prefix is added.
- Health-check success output is intentionally compact: the phase prints a short
  `Scanning..` line, each healthy host prints `[health-check] ok`, and there is
  no extra all-healthy footer.

## Timing Breadcrumbs

- The initial nixbot context should print the run start timestamp so a long
  captured log has an absolute anchor before the final summary appears.
- Build and deploy jobs should record per-host duration sidecars beside their
  status files and emit a small duration line when the job exits. This keeps
  timing correct for parallel jobs because each child process records its own
  elapsed time.
- The final summary should report wall-clock total time, build phase time, and
  deploy phase time. Build/deploy phase totals are operator wait time, not a sum
  of parallel host durations.

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
- `--ci-trigger --dirty-staged` is an explicit payload transport, not just a
  forwarded flag: the operator side sends staged changes on stdin, and the CI
  host applies them with index updates inside the isolated run worktree.
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
- `pkgs/tools/nixbot/nixos-module.nix`
- `scripts/nixbot.sh`
- `hosts/nixbot.nix`
- `hosts/common/all.nix`
- `hosts/common/ci.nix`
- `.github/workflows/nixbot.yaml`

## Provenance

- This note replaces the earlier dated deploy, bootstrap, SSH, locking,
  Terraform, and review-followup notes from March and April 2026.

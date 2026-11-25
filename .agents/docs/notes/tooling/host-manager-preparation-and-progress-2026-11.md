# Fleet preparation, admission and progress

## Command boundary

- `fleet prepare`: Build → Acquire. Native Nix pipeline only until other
  frontends explicitly support the action; unsupported dispatch fails before
  effects, never silently falls back.
- Acquisition selects built candidates independently of rollback snapshots.
  Deploy still captures its own current generations and repeats admission.
- Preparation writes stores/caches, may install declared identities and
  reconcile parent readiness; it never activates a generation or runs deployment
  health.
- First-activation prefetch deferral is a warning, not a fully prepared result.
- Release run-owned candidate roots on exit. Artifacts follow normal cache/GC
  retention. A subsequent deploy verifies/reacquires rather than trusts old
  preparation evidence. No durable prepare ticket or indefinite GC roots.

## Shared admission

- `fleet/admission.rs`: one invocation-owned control, scoped threads only for
  admitted work, condition-variable wakeup on completion or adjustment.
- One mutable operator value: `Option<usize>` target. No bonus/overflow counter.
  Until the first accepted key, normal stage/domain startup limits apply.
- `+`/`=` and `-` change the effective displayed target by one (minimum one).
  Accepted targets apply across all remaining stages, including activation;
  lowering never cancels admitted work. This supersedes the original per-pool
  adjustment design at the user's request. The override remains absolute, not a
  per-stage delta: `--jobs 8`, a two-host level and one `+` select 3 for later
  larger levels too. This is intentional; a per-stage delta is a different
  contract and can raise later concurrency above the operator's chosen limit.
- Startup effective capacity includes queued/admitted work and domain limits;
  completed domains cannot strand another at its soft limit. Manual targets
  replace soft startup limits, while explicit domain maxima remain hard.
- `--jobs-per-domain-max` / `NIXBOT_JOBS_PER_DOMAIN_MAX` must not be below the
  effective initial domain allowance. No change to Nix/compiler parallelism or
  backend authority. Idle/saturated keypresses are ignored, not banked.
- Dependency levels and control-plane exclusive builds remain caller-owned hard
  barriers. Parent readiness is also a coordinator-owned barrier: reconcile and
  settle each required parent once before snapshot/acquire/deploy admission;
  parallel workers perform host-local work only and never concurrently reconcile
  a shared parent. Removed fixed-capacity selection waves and the old parallel
  mapper. Retained selection comparison ignores only the obsolete `waves` hint;
  all selection/dependency facts and unknown fields still compare exactly.
- Publish terminal host outcomes once, immediately; reconcile state in stable
  order. Join every admitted deployment receipt before rollback. Admission stop
  policy remains phase-specific: build is fail-fast; build-plan evaluation and
  snapshot collection keep independent work running and stop only for
  withdrawal; required acquisition/deploy failure closes new admission while
  optional acquisition failure does not; health stops only for withdrawal.
- Cleanup failure adds context without erasing typed interruption. Host summary
  text and tone consume typed outcomes, never parse status prose.
- Root `NativeFleetEffects::execute` owns one reporter-scoped input guard for
  both native and retained workflows, released before summary even on failure.
  Worker construction never registers controls. `AdmissionInput` shares only
  invocation state, never a pool's defaults or dispatch authority.
- Scheduler snapshots own adjustability as well as occupancy and constraints.
  Registration alone never advertises keys: idle/stopped/empty waves,
  single-host selections and exclusive work have no live controls. Automatic log
  attribution is separate: multi-host phase output keeps one prefixed shape
  across exclusive substeps, draining and cancellation. Idle/saturated
  keypresses remain ignored without feedback; display availability never grants
  admission. No process-global scheduler, UI dependency in admission, or
  renderer-derived draining. A poisoned presentation lock disables controls
  without failing work.
- Typed key feedback and scheduler-reported number changes briefly use pink-red
  (xterm 204). The existing reader expires feedback after 800ms; no per-press
  thread/timer. Styling follows width selection, with pressed hints favored and
  cancellation always retained. Plain/redirected output has no transient
  feedback. Scheduler constraints expose only concise operator-relevant state:
  `draining`, `domain max`, `domain limit`, or `closed`; internal “no eligible
  hosts in this wave” explanations are intentionally omitted.
- Report domain blockage before global saturation, so an effective startup limit
  still explains the binding domain allowance and the `+` action.
- Phase results remain typed through summary rendering. Final host state is a
  composable `HostMilestone + HostQualifier` value rather than a flattened enum
  of every combination; presentation derives compact phrases from those two
  dimensions without parsing prose. Timing cells use recorded host outcomes;
  missing evidence means not run, never a skip inferred from phase prose.
  Resolve effective domain defaults in one preparation helper shared with native
  admission.
- Serial non-interactive builds retain evaluation caching. Adjustable pools
  disable it before parallel execution becomes possible.

## Acquire activity

- Closure transfer uses Nix path evidence; admission names the validator in
  flight. Identity and lease operations have a step and elapsed time, not a
  synthetic progress counter. Before any paths are copied, Nix `nix-cache-info`
  lookup retries show the reported attempt and backoff in the compact row;
  terminal lookup errors replace the last retry. URLs and raw errors are not
  copied into the compact view.
- Fleet opts candidate runners into item updates with
  `ABIRD_ACQUIRE_PROGRESS=1`. The compact row shows the current service or
  model, its 1-based position in the host plan, backend, action and outcome.
  Earlier lines remain in verbose output and diagnostics. Older candidates
  retain start/summary output.
- Image batch size is the number still missing after cache checks, not layers or
  a transfer percentage. Ollama bytes belong to one layer and are sampled at
  most once per second per request. HF has no inferred byte total; llama.cpp
  request acceptance is not download completion. Deferred is not ready.

## Timing and source identity

- Host-stage elapsed accumulates its steps, including retries and finalization,
  excluding gaps waiting for admission; overlapping intervals count once.
- Current step duration is additional detail only when distinct from the total.
- Stage elapsed is fleet wall time, never a sum of parallel host durations.
- Stage outcome, step outcome and scheduler occupancy are separate facts.
- Exact source identity is invocation metadata: print it once before build
  strategy after source authority is resolved, never repeat it in phase headers
  or the final summary. Build-strategy presentation receives the backend
  actually selected by the dispatcher; it never re-resolves `auto` from policy
  while rendering, so future auto-routing cannot make the displayed backend lie.
- Live phase headers keep the primary phase/title on one line; phase-local
  occupancy, outcomes and elapsed metadata wrap as indented muted semantic
  fields instead of truncating one long status line.
- Ordinary live host states use the shared compact stage/outcome vocabulary
  (`build done`, `snapshot skip`, `acquire skip`, `deploy blocked`,
  `health skip`). Benign skips are muted; blocked/deferred/unavailable states
  remain warning-colored but count as skipped; diagnostic failures keep detail.
- Initial selected hosts render as a parent tree with muted guides/metadata and
  stable identity-colored names; target and `via` are the only inline route
  metadata because parentage is structural.
- Compact completed-stage counts/times stay in the live dashboard. Final host
  rows use typed milestone/qualifier status plus measured-only compact timings:
  `[b2.8s s327ms a23s d11s h954ms]`; units stay explicit and skipped/not-run
  phases disappear from timing metadata. Successful skips before the action's
  final host goal (deploy for deploy/run, acquire for prepare, build for
  build/dev-build) mute the whole final row; warning/failure skip-like outcomes
  remain prominent. Preserve measured failures, interruptions and unconfirmed
  work, including observed hosts outside the final selection.
- Live elapsed time is stage wall time; total runtime appears once in the final
  summary metadata. Source identity is not phase state and has no extra `Run`
  row. No timing toggle; verbose remains a log-view control.
- Source identity comes from the actual isolated execution workspace. Staged
  source includes its applied-content fingerprint; plain dirty permission does
  not claim unconsumed edits. Development builds identify a mutable checkout.
- Retained backend identity comes from retained source metadata. Full identities
  annotate existing diagnostics best-effort after execution; short identities
  are presentation, not authority. Metadata alone never retains an empty run.

## Validation boundary

- 2026-11-17 architecture follow-up: canonical `fleet` parsing and help now
  share one Clap command schema; environment values remain the default layer and
  legacy `nixbot` performs action/argv translation only. The former canonical
  `parse_options` state machine is removed. Final host state is now
  `HostMilestone + HostQualifier` rather than a flattened combinatorial enum;
  interruption after completed build preserves both facts as
  `Built + Interrupted`.
- The exact post-refactor tree passed the deterministic full library suite
  (`622 passed, 2 ignored`), `cargo check --tests`,
  `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, and
  `git diff --check`. Current integration coverage includes `fleet_contract`
  (23/23), `fleet_prepare_cli` (6/6), `fleet_orchestration` (20/20),
  `fleet_binary` (17/17), summary-sensitive native-runtime cases, and fresh
  environment/strategy/CI/repository batches. The existing native-acquisition
  ABI test remains intentionally ignored when its external ABI/Nix fixture is
  unavailable.
- The earlier fresh review also exercised every integration-test target in
  bounded batches. A monolithic package invocation was externally terminated by
  L5 without a Rust/test diagnostic, so remaining targets were run separately
  from the warm build.
- The fresh review found and fixed execution-policy regressions introduced by
  the scheduler rewrite: parent readiness had moved into parallel workers
  (allowing concurrent reconcile/settle against one shared parent), and plan
  evaluation plus snapshot collection had accidentally become fail-fast. It also
  fixed interruption being retained as `build_failed` in the final host summary,
  strategy display re-resolving `auto` instead of using the chosen backend,
  stale final-summary test vocabulary, compact-duration rounding across minute/
  hour boundaries, and transient build-limit display using a stale default.
- Focused regressions additionally cover accepted-key feedback,
  attribution/control separation, saturated adjustment, scheduler constraint
  vocabulary, deploy/acquire skip state, compact final summaries, parent-tree
  inventory rendering, semantic phase-header wrapping, split summary metadata,
  grouped Clap fleet help/parity, and host-list route output. Fleet help ANSI
  styling was verified through a pseudo-TTY with `TERM=xterm-256color`.
- Reviewed package suite: 1,137 passed, 3 existing ignores (native acquisition
  ABI fixtures and a fresh-process harness entry).
- `cargo test -p abird-host-manager --locked --offline -j 1`: unit, integration,
  cancellation and terminal regression coverage.
- `nix fmt -- --project abird-host-manager`: passed.
- `nix run .#lint -- --diff --base <implementation-base> --project
  abird-host-manager`:
  formatting, lint and the complete package suite passed.
- Validation used one compilation job. No fleet builds, system builds or live
  deployment. Full-monorepo `nix flake check` not run; real rollout remains
  explicit.

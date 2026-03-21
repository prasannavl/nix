# Nixbot Deploy System Consolidated Notes (2026-03)

## Scope

Canonical durable state for the March 2026 `nixbot` deploy system: bastion
ingress, bootstrap and identity handling, dependency-aware orchestration,
snapshot/rollback rules, logging semantics, and CI connectivity.

## Core architecture

- `scripts/nixbot.sh` is the only supported orchestration entrypoint for local
  runs and bastion-triggered runs.
- Bastion ingress uses forced-command keys only; the normal `nixbot` SSH key
  remains a standard deploy/shell key from `lib/nixbot/default.nix`.
- Activation-time secret decrypt uses the host machine age identity at
  `/var/lib/nixbot/.age/identity`, not the deploy SSH key.
- Shared deploy SSH keys and per-host age identities are intentionally separate
  trust domains.

## Connectivity and bootstrap model

- Normal targeting prefers `nixbot@host`; bootstrap is fallback, not the
  default. `--bootstrap` forces the bootstrap path even if the primary path is
  healthy.
- Forced-command bootstrap probes should execute `nixbot ...` explicitly so SSH
  does not pass option-like arguments directly and the remote side can strip the
  leading command token independent of the bastion store path.
- When deploy and bootstrap users match, bootstrap-key installation is cached
  per host for the duration of one run.
- Bastion-triggered runs stay pinned to the installed bastion wrapper by
  default. The wrapper syncs a persistent repo root, creates a detached per-run
  worktree, and runs the deploy from that worktree without re-exec.
- Re-exec into the worktree copy of the script stays opt-in only
  (`--use-repo-script` / `NIXBOT_USE_REPO_SCRIPT=1`) and guarded against loops.
- Keep repo-script re-exec disabled in CI and routine forced-command use: it
  bypasses the normal "deploy bastion logic first, then rely on it later" trust
  boundary.
- `--bastion-trigger` must forward explicit behavior overrides that affect
  deploy gating, including `--force`, so the bastion-side run preserves the
  caller's changed-only vs force semantics.
- Deploys that use `ssh -tt` for remote `sudo` must resolve the stdin source at
  the point of use: use `/dev/tty` only when any attached standard stream is a
  terminal, otherwise fall back to `/dev/null`. Non-interactive bastion-side
  runs must not probe `/dev/tty` eagerly.

## Identity, keys, and host verification

- `hosts/nixbot.nix` maps activation identities with
  `hosts.<name>.ageIdentityKey = "data/secrets/machine/<host>.key.age"`.
- Deploy injects that identity to `/var/lib/nixbot/.age/identity` before
  activation.
- Because `scripts/nixbot.sh` may also use that path as a local fallback decrypt
  identity (for example during bastion-side Terraform runtime secret loading),
  the runtime path must be readable by the `nixbot` user, not just by root.
- Runtime secret decryption should use the shared candidate identity list for
  all `*.age` files, not a Cloudflare-specific special case.
- Per-identity `age` stderr should stay buffered unless every candidate identity
  fails, so successful fallback decrypts do not flood bastion logs with repeated
  `no identity matched` noise.
- Keep `/var/lib/nixbot/.age` traversable by `nixbot` and the identity file
  group-readable by `nixbot` while preserving root ownership. The current model
  is directory `0710 root:nixbot` and file `0440 root:nixbot`.
- `/var/lib/nixbot` itself is part of the shared deploy contract on every host,
  not just bastion hosts. The home directory must exist as `0755 nixbot:nixbot`
  before any shell startup, snapshot probe, or deploy probe connects as
  `nixbot`.
- Bastion deploy keys remain normal `age.secrets.*` material under
  `/var/lib/nixbot/.ssh`.
- If bootstrap replaces `/var/lib/nixbot/.ssh/id_ed25519`, the old key is kept
  as `/var/lib/nixbot/.ssh/id_ed25519_legacy`; bastion-side SSH tries current
  first, then legacy.
- All bastion-managed SSH uses strict host-key checking with dedicated temporary
  `known_hosts` files.
- `--bastion-trigger` prefers provided bastion host keys and only falls back to
  `ssh-keyscan -H <bastion-host>` when needed; absence of host-key material is
  fatal.
- If `NIXBOT_BUILD_HOST` differs from the target, that host must also be added
  to temporary `known_hosts` so remote copy/build hops succeed.
- Deploys use committed Git state only. The shared repo root must stay clean,
  and every run executes from a detached worktree rather than from the shared
  mirror itself.

## Orchestration rules

- Host metadata may declare `hosts.<name>.deps = [ ... ]` in `hosts/nixbot.nix`.
- Selected hosts are expanded to include selected hosts' dependencies, then
  topologically ordered.
- Explicit `--hosts a,b,c` order remains the stable tie-breaker when multiple
  hosts are ready at once.
- Build and deploy are separate concurrency domains:
  - build: `NIXBOT_BUILD_JOBS` / `--build-jobs`
  - deploy: `NIXBOT_JOBS` / `--deploy-jobs`
- Build can run across all selected hosts in parallel and still completes before
  deploy starts.
- Deploy is wave-based: a host only enters a wave after its selected
  dependencies have succeeded.
- `NIXBOT_BASTION_FIRST` / `--bastion-first` is a narrow override: if bastion is
  selected, it can be forced to the front of build order and wave 1 even if its
  own `deps` would place it later.
- Unknown selected hosts, unknown dependencies among selected hosts, or cycles
  in the selected dependency graph must fail the run before build/deploy starts.
- `--action all` is the default public mode:
  - run the TF phase first only when TF-relevant paths changed, unless `--force`
    overrides the skip
  - then continue with the normal host build + deploy flow
- Terraform phase membership should come from explicit per-phase project lists
  in `scripts/nixbot.sh`, not from filesystem discovery. The runnable set should
  live in one canonical project list, with per-phase membership derived from the
  `tf/<provider>-<phase>` name suffix. Commenting a project in or out of that
  canonical list is the supported enable/disable switch.
- `--action tf/<project>` should run exactly one configured Terraform project
  through the same change-detection, logging, summary, and bastion-trigger flow
  as the phase-wide Terraform actions.
- TF change detection lives only in `scripts/nixbot.sh` and currently covers:
  - `tf/**`
  - `data/secrets/cloudflare/*.age`
  - `data/secrets/tf/**`
- Terraform secret tfvars should load by convention from
  `data/secrets/tf/<provider>/` first and `data/secrets/tf/<project>/` second,
  so provider-wide defaults stay centralized while project-specific overrides
  follow the runnable `tf/<project>` roots.
- Terraform change detection should treat both of those secret scopes as inputs
  to the matching runnable project, including direct
  `data/secrets/tf/<provider>.tfvars.age` and
  `data/secrets/tf/<project>.tfvars.age` files when present.
- `--dry` stays a flag, not a separate action:
  - `all --dry` means TF plan-only when needed, then build/deploy dry-run
  - `deploy --dry` keeps the host deploy dry-run behavior
  - `tf --dry` runs TF plan-only

## Snapshot and rollback semantics

- Rollback safety is tied to recording the host's pre-deploy
  `/run/current-system` generation before that host deploys.
- Only wave 1 is snapshotted up front. Later waves are snapshotted on demand
  right before their deploy wave.
- Initial snapshot failures for later-wave hosts are deferred, not fatal.
- A host whose rollback snapshot still cannot be captured when its wave is
  reached must not deploy.
- Final summary semantics should preserve the true terminal state:
  - snapshot-blocked hosts: `FAIL (snapshot)`
  - built-but-never-deployed hosts after a global failure: `built`
  - deployed-then-reverted hosts after another host fails: `rolled back`

## Flow and logging lessons

- Sequential and parallel control flow should share helpers and data shaping so
  behavior does not drift between modes.
- Keep `run_hosts` as a thin orchestrator. Build-phase setup, snapshot retry
  handling, and deploy-wave execution should live in dedicated helpers so
  rollback/failure semantics stay aligned across future edits.
- Keep `main` phase-oriented: argument parsing, optional bastion-trigger hop,
  optional TF phase, then host orchestration should remain split across small
  top-level helpers rather than one large control-flow block.
- Keep the file organized in broad in-file sectors rather than many tiny
  scattershot helper regions. The current stable split is:
  - core helpers
  - repo workspace
  - config and secrets
  - host selection
  - deploy target and SSH context
  - host phases and host phase artifacts
  - build and deploy phases
  - Terraform
  - logging
  - dispatch and main
- Small repeated Bash/JSON conversion patterns should stay centralized in helper
  functions so host selection, bootstrap checks, and run-context setup do not
  each open-code `jq` plus `mapfile` list materialization.
- Nested Bash nameref helpers must not reuse the caller's local variable names
  (for example `foo_ref` passed to a helper that also declares
  `local -n foo_ref=...`), or Bash 5.3 emits circular-name-reference warnings
  and the helper may not update the intended array.
- Stronger nested-helper rule: when a nameref helper calls another nameref
  helper, do not forward the helper-local alias name as a bare argument. Pass
  the original target-name parameters instead, and prefer short
  function-specific nameref aliases such as `rdp_*`/`rps_*` over generic names
  like `failed_hosts_out_ref`. With function-prefixed nameref aliases, `_local`
  should be added only when the shorter alias would collide with another name
  already used in scope or elsewhere in the script.
- If the helper shifts positional parameters, capture those target-name
  parameters into ordinary locals before `shift`; otherwise the forwarded names
  no longer refer to the intended caller arrays.
- Shared SSH-context assembly should stay centralized in
  `prepare_host_ssh_contexts`, and repeated SSH key resolve-and-validate logic
  should stay centralized in `resolve_ssh_identity_file`.
- Keep `PREP_*` as the shared deploy-context store, but only read it through
  small materialization helpers (`use_prepared_*`) so per-host phases take the
  minimum context they need instead of reaching into globals directly.
- Reset `PREP_*` once at the start of `prepare_deploy_context`; failed
  preparation must not leave stale context behind for later phases.
- Do not rely on `set -e` to abort later commands inside a command substitution
  or grouped command used for assignment. If a preparation step must gate the
  next command, test it explicitly before running the probe/action.
- Materialize dependency-wave JSON into shell arrays before foreground
  `ssh`/`nixos-rebuild` loops; otherwise stdin consumption can silently truncate
  later waves.
- Logging should stay plain text and stderr-oriented, but consistently mark:
  - top-level phases
  - per-host stage banners
  - deploy/snapshot wave boundaries
  - host-prefixed streamed output when jobs run in parallel
- In GitHub Actions log mode, Terraform phase sections should remain grouped at
  the phase level, with per-project groups nested inside them rather than
  replacing the phase group.
- In GitHub Actions log mode, Terraform should stream normally inside those
  phase/project groups rather than using a separate buffered log path.
- Keep `Phase` and `Wave` headings directly adjacent with no extra blank
  separator, but preserve a blank line before each host-stage banner (for
  example between `--- ... Wave ... ---` and
  `---------- host | snapshot ----------`).
- When deploy temporarily re-enters snapshot retry work, logs must print
  `Phase: Snapshot` before the retry and `Phase: Deploy` when returning, so the
  phase transition is explicit.
- Per-host preparation helpers must return failures up to the wave controller;
  they must not terminate the whole script directly, or rollback will be
  skipped.
- Final phase summary output should place `Result: ...` on its own separated
  line after the host/failure summary, without an extra trailing blank line
  after the result itself.

## CI state

- `.github/workflows/nixbot.yaml` uses Tailscale OAuth/OIDC instead of the old
  auth-key flow.
- `scripts/nixbot.sh` always re-execs into one pinned `nix shell` runtime.
  Normal repo-root runs use `--inputs-from <repo-root>`; SSH forced-command
  ingress skips `--inputs-from` and falls back to `nixpkgs#...` installables so
  the bastion wrapper does not depend on flake root discovery.
- The runtime toolchain contract is declared once and reused for shell entry,
  `--ensure-deps`, and normal runtime verification. The shared toolset is:
  `age`, `git`, `jq`, `nixos-rebuild`, `openssh`, and `opentofu`.
- Bastion-side Terraform automation must run `tofu init` with
  `-lockfile=readonly` so provider lock normalization does not dirty a repo
  worktree during PR-triggered deploy runs.
- Terraform backend selection should stay centralized by runnable project:
  Cloudflare roots and `gcp-bootstrap` use the shared R2 backend, while
  `gcp-platform` uses GCS. Runtime secret loading, required env validation, and
  wrapper/backend-config injection should all reuse that same backend convention
  helper instead of open-coding per-project branches.
- The persistent bastion repo root may be synced to `origin/master` only during
  the short locked setup window before a worktree is created. The source mirror
  must never be the active execution tree for a run, including `master` deploys,
  so later syncs cannot perturb in-flight runs.
- Required workflow traits are:
  - `tailscale/github-action@v4`
  - `permissions.id-token: write`
  - `oauth-client-id`, `audience`, and `tags: tag:ci`
  - generated per-run `TS_HOSTNAME`
- GitHub-hosted runners must install Nix before invoking the packaged `nixbot`
  entrypoint.
- The workflow should warm the shared runtime closure before the main deploy
  step by calling `nix run path:.#pkgs.$system.nixbot -- --ensure-deps
  > /dev/null`; treat that warmup as runner-local priming rather than as a
  > GitHub Actions cache-backed artifact distribution layer.
- Manual dispatch should stay aligned with the script surface:
  `action = all|build|deploy|tf|tf-dns|tf-platform|tf-apps|tf/<project>`, plus
  `dry` and `force`.
- The separate TF-only workflow was removed; the main `nixbot` workflow
  delegates TF gating decisions to `scripts/nixbot.sh`.

## Maintenance guidance

- Add new deploy behavior once in shared helpers, not by splitting sequential
  and parallel paths again.
- Build SSH option lists through shared helpers for known-hosts and identity
  overlays; do not duplicate primary/bootstrap option assembly in-line.
- Preserve the trust boundary between the installed bastion wrapper and freshly
  checked-out repo code unless a run explicitly opts out.
- Treat dependency metadata as orchestration hints only; it is not a substitute
  for host-level correctness or service readiness checks.

## Superseded notes

- `docs/ai/notes/nixbot/bastion-reexec-checked-out-script-2026-03.md`
- `docs/ai/notes/nixbot/deploy-flow-consolidation-2026-03.md`
- `docs/ai/notes/nixbot/deploy-log-formatting-2026-03.md`
- `docs/ai/notes/nixbot/deploy-noninteractive-tty-fallback-2026-03.md`
- `docs/ai/notes/nixbot/deploy-order-deps-2026-03.md`
- `docs/ai/notes/nixbot/deploy-snapshot-fallback-2026-03.md`
- `docs/ai/notes/nixbot/deploy-snapshot-retry-phase-logging-2026-03.md`
- `docs/ai/notes/nixbot/deploy-summary-built-status-2026-03.md`
- `docs/ai/notes/nixbot/deploy-summary-snapshot-status-2026-03.md`
- `docs/ai/notes/nixbot/github-actions-nix-bootstrap-2026-03.md`
- `docs/ai/notes/nixbot/cloudflare-apps-worker-build-and-age-fallback-2026-03.md`
- `docs/ai/notes/nixbot/github-actions-runtime-warmup-and-cache-2026-03.md`
- `docs/ai/notes/nixbot/log-stream-ordering-2026-03.md`
- `docs/ai/notes/nixbot-bastion-key-model.md`
- `docs/ai/notes/nixbot-bastion-legacy-identity-retention.md`
- `docs/ai/notes/nixbot-bastion-manual-key-decrypt-activation.md`
- `docs/ai/notes/nixbot-deploy-bootstrap-flag.md`
- `docs/ai/notes/nixbot-deploy-flow-consolidated-2026-03.md`
- `docs/ai/notes/nixbot-forced-command-bootstrap-check-bash-dash-error.md`
- `docs/ai/notes/nixbot-github-actions-bastion-known-hosts-fallback-2026-03-09.md`
- `docs/ai/notes/nixbot-github-actions-tailscale-oauth-migration.md`
- `docs/ai/notes/nixbot-machine-age-identity-model.md`
- `docs/ai/notes/nixbot/nixbot-home-dir-perms-2026-03.md`
- `docs/ai/notes/nixbot-remote-build-known-hosts-2026-03-09.md`
- `docs/ai/notes/nixbot/runtime-shell-consolidation-2026-03.md`
- `docs/ai/notes/nixbot/runtime-toolchain-unification-2026-03.md`
- `docs/ai/notes/nixbot/nixbot-deploy-cleanup-2026-03.md`
- `docs/ai/notes/services/nixbot-all-tf-gating-2026-03.md`

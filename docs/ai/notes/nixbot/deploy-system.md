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
  first-class modes: deploy, build, Terraform phases, dependency checks, and
  bootstrap checks.

## Core architecture

- `nixbot` is the only supported orchestration entrypoint for local, CI, and
  bastion-triggered runs.
- The deploy system separates:
  - SSH deploy identity
  - per-host machine age identity
  - bastion forced-command ingress identity
- Worktree isolation is for concurrency and checkout safety, not for reducing
  operator trust.

## Connectivity and bootstrap model

- Normal targeting prefers `nixbot@host`. Bootstrap is a fallback path unless
  explicitly forced.
- Bastion-triggered runs may flatten leading self-targeting proxy hops, but they
  must retry the full configured proxy chain before falling back to bootstrap.
- Self-target deploys should execute locally only when the current runtime user
  is already the deploy user. Local operator runs should preserve the normal
  `nixbot` SSH trust boundary.
- Generated proxy wrappers must preserve per-hop SSH users and identity files
  and emit IPv6-safe forwarding targets.
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
  bootstrap user, fail early instead of letting remote closure import fail
  later.
- Host age identity injection is a standard pre-activation step. The runtime
  path must be readable by `nixbot`, not only by root.
- Prepare host age identity material once per host and reuse the resolved file
  and checksum across prechecks, injection, and activation-context validation.
- Activation-context visibility probes must use explicit
  `/run/current-system/sw/bin` paths inside transient units.

## Runtime workspace and locking

- Each run should allocate one workspace root that contains:
  - the detached repo worktree
  - logs
  - runtime secrets
  - SSH temp state
- Managed repo locking must cover the first clone path as well as steady-state
  repo refreshes.
- Repo-root locks must recover from stale owners rather than spinning forever.
- `--dirty-staged` overlays must fail closed if the cached diff cannot be
  applied cleanly.

## SSH transport rules

- Keep stdout and stderr separate for machine-readable remote helpers.
- Critical remote helpers should treat `/run/current-system/sw/bin` as the
  runtime contract instead of relying on ambient PATH.
- Safe idempotent remote operations may use bounded transport retries. Mutating
  steps should remain intentionally narrower to avoid duplicate side effects.
- Remote file installation should retry transport failures for temp allocation,
  copy, and install execution.

## Deploy orchestration

- Snapshot work and deploy work both use the deploy parallelism budget within a
  dependency wave.
- Parent-host readiness failures must propagate real command failures; do not
  swallow exit status through Bash `if` compound semantics.
- Host selection and helper naming should keep classification side-effect free:
  `prepare_*` for setup, `resolve_*` or `evaluate_*` for classification.
- Avoid scalar `local -n` output helpers when stdout capture or shared prepared
  context is simpler and safer.

## Terraform dispatch

- `tf`, `tf-dns`, `tf-platform`, `tf-apps`, and `tf/<project>` should bypass
  host orchestration setup and go straight to the Terraform flow.
- Runtime secret loading should use the shared age-identity candidate list, not
  provider-specific special cases.
- Fresh worktrees expose stale Terraform lockfile state immediately, so deploy
  automation should keep `-lockfile=readonly` and fix lockfiles rather than
  mutating them during deploy.

## CI and bastion trigger model

- The GitHub Actions workflow is a thin launcher that warms the local runner,
  runs lint, and triggers the bastion-hosted deploy flow.
- The bastion host owns the persistent repo, store, and worktree state.
- Bastion-triggered forwarding should use encoded argv transport. Legacy raw
  `SSH_ORIGINAL_COMMAND` parsing remains only as a narrow compatibility path.
- Bastion-triggered operators are trusted deploy operators. If tighter SHA or
  ref policy is needed later, enforce it explicitly.

## Key rotation

- Overlap rotation is the default for SSH deploy keys.
- Keep design memory in `docs/ai/notes/nixbot/key-rotation.md` and the
  step-by-step execution in the key-rotation playbooks.

## Source of truth files

- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/default.nix`
- `pkgs/tools/nixbot/flake.nix`
- `scripts/nixbot.sh`
- `hosts/nixbot.nix`
- `lib/nixbot/default.nix`
- `lib/nixbot/bastion.nix`
- `.github/workflows/nixbot.yaml`

## Provenance

- This note replaces the earlier dated deploy, bootstrap, SSH, locking,
  Terraform, and review-followup notes from March and April 2026.

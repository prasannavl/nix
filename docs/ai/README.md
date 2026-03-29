# AI Docs Index

Use this index as the canonical map for `docs/ai/**`.

## Lang Patterns

- `docs/ai/lang-patterns/common.md`: Cross-language code-practice defaults,
  including the common line-width recommendation: `100` for code, `80` for
  comments, and `120` as the hard maximum.
- `docs/ai/lang-patterns/bash.md`: Bash entrypoint structure, initialization,
  `nameref` minimization, and `nix shell` runtime dependency rules for repo
  scripts.
- `docs/ai/lang-patterns/markdown.md`: Markdown formatting authority, lint
  interaction, and `docs/ai` writing conventions for repo-generated docs.
- `docs/ai/lang-patterns/nix.md`: Nix formatting, `inherit` conventions, module
  patterns, attrset style, packaging conventions, flake conventions, and common
  pitfalls.

## Notes

### Apps

- `docs/ai/notes/apps/default-nix-nix-build-compat-2026-03.md`: Keep package
  `default.nix` files as the canonical definitions and add legacy-compatible
  defaults so they work with both `callPackage` and `nix-build`.
- `docs/ai/notes/apps/flake-architecture-consolidated-2026-03.md`: Canonical
  flake output model, auto-discovery collector, `lib/flake` helpers, hybrid
  package set architecture, and wrapper flakes.
- `docs/ai/notes/apps/flake-app-meta-simplification-2026-03.md`:
  `meta.mainProgram` as single source of truth for app binaries, flake warning
  cleanup, and lint stderr filtering.

### Deployment

- `docs/ai/notes/deployment/deployment-fixes-consolidated-2026-03.md`: Small
  deployment unblockers with lasting operational value.

### Hosts

- `docs/ai/notes/hosts/cloudflare-tunnel-hosts-2026-03.md`: Reusable Cloudflare
  Tunnel host wiring.
- `docs/ai/notes/hosts/desktop-investigations-consolidated-2026-03.md`:
  Consolidated desktop investigations and durable findings.
- `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md`: Canonical
  reusable Incus guest template, bootstrap flow, naming conventions, and secret
  model.
- `docs/ai/notes/hosts/incus-machines-module-2026-03.md`: Reusable
  `lib/incus.nix` NixOS module for declarative incus container lifecycle: device
  sync, config-hash recreate, bootTag/recreateTag, GC, and per-device removal
  policies.
- `docs/ai/notes/hosts/incus-machine-images-2026-03.md`: Per-machine Incus base
  image selection, global multi-image `imageTag` refresh, and guest recreate
  behavior for image changes.
- `docs/ai/notes/hosts/nested-incus-bastion-pattern-2026-03.md`: Nested Incus
  bastion-host pattern with GPU passthrough, Podman services, an inner guest,
  and `dir` storage to avoid btrfs-on-btrfs.
- `docs/ai/notes/hosts/bash-prompt-exit-status-fix-2026-03.md`: Prompt
  exit-status command substitution was escaped as `\$(...)` during lint cleanup,
  causing the literal text to render in interactive shells.

### Lib

- `docs/ai/notes/lib/lib-broader-review-fixes-2026-03.md`: Broader `lib/` review
  fixes for the NetworkManager resume hook, optional guest Tailscale ownership,
  and Flatpak bootstrap runtime dependencies.
- `docs/ai/notes/lib/incus-device-arg-safety-2026-03.md`: `lib/incus.nix`
  device-add shell-argument safety fix, JSON-loop hardening, and cleanup of the
  dead helper plus unused lambda bindings.
- `docs/ai/notes/lib/incus-ip-conflict-assert-and-gc-fail-closed-2026-03.md`:
  Add duplicate guest IPv4 assertions and make Incus GC fail closed when
  container listing fails.

### Nixbot

- `docs/ai/notes/nixbot/code-review-and-cleanup-2026-03.md`: Consolidated code
  review, subprocess reduction, dedup, and simplification pass.
- `docs/ai/notes/nixbot/bastion-self-target-and-proxy-flattening-2026-03.md`:
  Bastion-triggered runs should execute the bastion host locally instead of
  self-SSH, and should drop leading `proxyJump` hops that resolve to the current
  host.
- `docs/ai/notes/nixbot/context-and-classifier-cleanups-2026-03.md`: Naming
  rules for helpers: `prepare_*` for state setup, `resolve_*`/`evaluate_*` for
  classification, and separation of discovery from materialization.
- `docs/ai/notes/nixbot/deploy-env-prefix-rename-2026-03.md`: Rename
  deploy-script-owned `DEPLOY_*` variables and env knobs to `NIXBOT_*`.
- `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md`: Canonical
  `nixbot` deploy architecture, runtime contract, orchestration behavior, deploy
  policy modes, host ordering edges, and result processing architecture.
- `docs/ai/notes/nixbot/dirty-flag-bypass-2026-03.md`: Explicit `--dirty` /
  `NIXBOT_DIRTY` opt-in for bypassing the repo-root cleanliness gate.
- `docs/ai/notes/nixbot/entrypoint-and-packaging-2026-03.md`: Canonical
  entrypoint layout, CLI design, flake packaging model, and wrapper exception.
- `docs/ai/notes/nixbot/error-handling-and-control-flow-2026-03.md`: Exit status
  preservation, signal handling, phase gating, and Terraform failure
  propagation.
- `docs/ai/notes/nixbot/gcp-platform-phase-disabled-2026-03.md`: Default
  `all`/`tf-platform` deploy phases no longer include `gcp-platform`; run it
  only via explicit `tf/gcp-platform`.
- `docs/ai/notes/nixbot/github-actions-workflow-design-2026-03.md`: GitHub
  Actions workflow design: action input scope, runtime warmup strategy, and thin
  launcher role.
- `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md`:
  Canonical `nixbot` rotation model, lessons, and operator guardrails.
- `docs/ai/notes/nixbot/lint-gating-and-precommit-2026-03.md`: Shared lint
  entrypoint, CI gate, and pre-commit hook decisions.
- `docs/ai/notes/nixbot/local-declaration-collapse-style-2026-03.md`: User-led
  Bash local-declaration style update to allow grouped `local` statements.
- `docs/ai/notes/nixbot/nameref-shadowing-audit-and-fixes-2026-03.md`:
  Consolidated bash nameref shadowing audit, function-specific alias
  conventions, and all nameref collision fixes.
- `docs/ai/notes/nixbot/nameref-output-shadowing-regression-2026-03.md`:
  Snapshot regression root cause after the deploy-context nameref refactor and
  the durable guardrail for helper output names versus scratch locals.
- `docs/ai/notes/nixbot/proxy-hop-auth-and-staged-overlay-2026-03.md`:
  Intentional bastion-trigger forwarding restriction, proxy-hop user/key
  preservation in SSH wrappers, and fail-closed staged overlay behavior.
- `docs/ai/notes/nixbot/review-fixes-2026-03.md`: Review-driven fixes for
  forced-command bootstrap validation, Terraform-only dispatch, and managed
  repo-root locking.
- `docs/ai/notes/nixbot/nixbot-incus-fresh-review-2026-03.md`: Fresh review of
  `pkgs/nixbot` and `lib/incus` covering parent-readiness error propagation,
  Incus exact-instance lookup safety, and nixbot package runtime tool closure.
- `docs/ai/notes/nixbot/parented-snapshot-readiness-loop-2026-03.md`: Replace
  the failed guest-specific `wait` workaround with a bounded readiness loop that
  waits for actual snapshot-path SSH success on parented hosts.
- `docs/ai/notes/nixbot/remote-file-install-transport-retries-2026-03.md`: Make
  remote temp-file allocation, file copy, and install steps retry on transport
  resets instead of failing fresh guest deploys immediately.
- `docs/ai/notes/nixbot/preactivate-age-identity-force-reinstall-2026-03.md`:
  Force the final pre-activation machine age identity injection instead of
  trusting a stale "already present" check on fresh Incus guests.
- `docs/ai/notes/nixbot/preactivate-age-identity-recheck-2026-03.md`:
  Deploy-time second check that reinstalls `/var/lib/nixbot/.age/identity`
  immediately before activation when the target copy vanished or changed.
- `docs/ai/notes/nixbot/runtime-temp-suffix-alignment-2026-03.md`: Consolidated
  per-run workspace root for deploy artifacts and detached repo worktrees.
- `docs/ai/notes/nixbot/security-trust-model-2026-03.md`: Bastion-trigger
  operator trust boundary, arbitrary-SHA policy, and relationship between
  worktree isolation and secret access.
- `docs/ai/notes/nixbot/snapshot-wave-parallelism-2026-03.md`: Snapshot work now
  uses the deploy parallelism budget so hosts in the same dependency wave
  snapshot concurrently.
- `docs/ai/notes/nixbot/worktree-terraform-lockfile-2026-03.md`: Terraform
  lockfile regression exposed by fresh deploy worktrees and the normalization
  rule for Cloudflare provider locks.

### Reviews

- `docs/ai/notes/reviews/nixbot-and-incus-architecture-review-2026-03.md`:
  Architecture, correctness, and refactoring review of `pkgs/nixbot/nixbot.sh`
  and `lib/incus.nix`.

### Secrets

- `docs/ai/notes/secrets/age-secrets-clean-flag-2026-03.md`: Managed secret
  cleanup behavior for `scripts/age-secrets.sh`.
- `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md`:
  Canonical secret topology, trust domains, and bootstrap order.

### Services

- `docs/ai/notes/services/bastion-and-podman-consolidated-2026-03.md`: Canonical
  podman compose platform model, bastion service migration, config
  centralization, secret injection, and systemd lifecycle.
- `docs/ai/notes/services/cloudflare-consolidated-2026-03.md`: Canonical
  Cloudflare OpenTofu architecture, adoption status, source-of-truth rules,
  tunnel adoption plan, and operational procedures.
- `docs/ai/notes/services/docs-sensitive-info-cleanup-2026-03.md`: Documentation
  cleanup rules for sensitive operational details.
- `docs/ai/notes/services/gcp-terraform-adoption-2026-03.md`: GCP bootstrap and
  platform Terraform adoption into this repo's phase-based `tf/` layout.
- `docs/ai/notes/services/automatic-ingress-metadata-2026-03.md`: Optional
  `exposedPorts` metadata that auto-derives nginx reverse-proxy and Cloudflare
  Tunnel wiring. Includes nginx proxy abstraction supporting multiple upstreams
  and non-podman vhosts via a unified `proxyVhostType`.
- `docs/ai/notes/services/incus-post-activation-reconcile-and-nixbot-settle-2026-03.md`:
  Canonical Incus parent/child orchestration model: host-side reconcile and
  settle helpers, safe policy defaults, nested-host failure lessons, and
  `nixbot` readiness barriers.
- `docs/ai/notes/services/lib-service-module-relocation-2026-03.md`: User-led
  relocation of service-specific helper modules from `lib/` into
  `lib/services/`.
- `docs/ai/notes/services/lib-flake-published-podman-systemd-modules-2026-03.md`:
  Revert `podman` and `systemd-user-manager` to `lib/` and drop the unused
  published flake-module export.
- `docs/ai/notes/services/lib-review-followup-2026-03.md`: Follow-up review
  decisions for `lib/incus.nix`, `lib/podman.nix`, and
  `lib/systemd-user-manager.nix`, including the user correction on inactive-unit
  semantics, the Podman `recreateTag` fix, the Incus start failure fix, and the
  `pvl-x2` boot activation root cause.
- `docs/ai/notes/services/module-review-podman-systemd-user-manager-fixes-2026-03.md`:
  Review-driven fixes for generated service-name collisions in `podman` and
  `systemd-user-manager`, plus serialized Podman lifecycle-tag action units.
- `docs/ai/notes/services/openssh-module-centralization-2026-03.md`: Shared
  OpenSSH enablement centralization.
- `docs/ai/notes/services/podman-compose-reload-staging-2026-03.md`: Podman
  compose runtime files are copied into working directories and reload now
  performs cleanup plus restaging before `up -d`.
- `docs/ai/notes/services/podman-compose-start-state-verification-2026-03.md`:
  Generated podman compose units now fail fast when `up -d` leaves any container
  stuck in `Created` or another bad non-running state.
- `docs/ai/notes/services/podman-compose-runtime-path-conflicts-and-startup-readiness-2026-03.md`:
  Generated podman compose staging now removes file-versus-directory conflicts
  cleanly, and compose units only report startup success after verification
  completes.
- `docs/ai/notes/services/podman-compose-wait-supervision-2026-03.md`: Main
  generated podman compose units use a long-running monitored service model so
  systemd can observe runtime failure and restart stacks on failure.
- `docs/ai/notes/services/podman-lifecycle-tag-semantic-stamps-2026-03.md`:
  Podman lifecycle tags now use explicit semantic stamp payloads so `imageTag`,
  `bootTag`, and `recreateTag` only react to declared tag-value changes.
- `docs/ai/notes/services/shared-collections-helper-2026-03.md`: Shared
  `lib/flake/utils` helper for reusable pure-Nix collection utilities such as
  duplicate-value detection.
- `docs/ai/notes/services/systemd-user-manager-bridge-lifecycle-2026-03.md`:
  Canonical `lib/systemd-user-manager.nix` bridge model, reload orchestration,
  old-stop/new-start semantics, identity refresh behavior, and Podman usage
  pattern.
- `docs/ai/notes/services/systemd-user-manager-first-run-naming-2026-03.md`:
  Final first-run naming for `systemd-user-manager`: `startOnFirstRun` for
  units, `stopOnRemoval` for removal behavior, and `execOnFirstRun` for actions.
- `docs/ai/notes/services/systemd-user-manager-inactive-action-naming-2026-03.md`:
  Clearer action naming for inactive observed-unit behavior:
  `observeUnitInactiveAction`, `run-action`, and `start-change-unit`.
- `docs/ai/notes/services/systemd-user-manager-stable-state-backoff-2026-03.md`:
  Progressive stable-state polling backoff and clearer timeout handling for
  user-unit reconcile waits.
- `docs/ai/notes/services/systemd-user-manager-boot-deferral-2026-03.md`: Boot
  activation now skips all mutating `systemd-user-manager` activation-script
  work; the reconciler runs later as a normal boot unit, and boot-gated user
  services wait on a ready target it starts after a successful apply.
- `docs/ai/notes/services/systemd-user-manager-dispatcher-reconciler-redesign-2026-03.md`:
  Detailed handoff plan for the next `systemd-user-manager` redesign: thin
  system-side per-user dispatcher, user-side reconciler owning all user-unit
  mutation, stateless dispatch, full postmortem of the boot activation and PAM
  storm regressions, and phased implementation guidance.
- `docs/ai/notes/services/systemd-user-manager-dry-activate-preview-2026-03.md`:
  `dry-activate` now logs the per-user reconcile actions it would take without
  mutating user services or persisted stamp state.
- `docs/ai/notes/services/systemd-user-manager-per-user-apply-and-podman-actions-2026-03.md`:
  Refactor `lib/systemd-user-manager.nix` to one serialized apply service per
  user and move Podman lifecycle tags to transient user-manager actions instead
  of persistent bridged user units.
- `docs/ai/notes/services/nixbot-incus-guest-snapshot-wait-2026-03.md`: `nixbot`
  now reuses host `wait` values before retrying rollback snapshots for newly
  recreated Incus guest targets.
- `docs/ai/notes/services/nginx-compose-config-bind-mounts-2026-03.md`: Nginx
  compose config migration from a legacy local tree into repo-managed
  bind-mounted files.

### Tooling

- `docs/ai/notes/tooling/code-practices-line-width-2026-03.md`: Evidence-based
  supporting analysis and references for the common line-width recommendation.
- `docs/ai/notes/tooling/bash-entrypoint-and-runtime-shell-conventions-consolidated-2026-03.md`:
  Canonical Bash entrypoint structure, runtime-shell re-exec rules, and thin
  wrapper exceptions.
- `docs/ai/notes/tooling/lint-workflow-consolidated-2026-03.md`: Canonical lint
  contract for read-only validation and the `statix fix` per-target CLI
  constraint.
- `docs/ai/notes/tooling/flake-check-path-input-fix-2026-03.md`: Lint
  `nix flake check` must `cd` into the sub-flake directory (not use `path:` URI)
  so sibling `path:` inputs resolve via the parent git tree.
- `docs/ai/notes/tooling/lint-ci-mode-and-root-check-2026-03.md`: Lint modes
  cleanup (auto/diff/full-no-test/full), root flake check in every mode, and
  sub-flake test filtering convention.
- `docs/ai/notes/tooling/pre-push-per-commit-lint-2026-03.md`: Pre-push hook
  replaces pre-commit; lints each commit individually via `--diff --base`.
- `docs/ai/notes/tooling/update-flakes-script-2026-03.md`:
  `scripts/update-flakes.sh` for recursively updating all flake lock files.
- `docs/ai/notes/tooling/tf-selective-cloudflare-state-migration-2026-03.md`:
  Selective two-phase Cloudflare state transfer planning with separate
  import-into-target and remove-from-source command files, including selectors
  for zones, workers, tunnels, and R2 buckets.
- `docs/ai/notes/tooling/vscode-configuration-2026-03.md`: Consolidated VS Code
  upstream package model, pinned hash strategy, and Go toolchain provisioning.

## Playbooks

- `docs/ai/playbooks/ai-docs-reconsolidation.md`: Periodic cleanup workflow for
  reconsolidating `docs/ai/notes`, folding completed `runs` back into notes,
  sanitizing durable identifiers, and refreshing the index.
- `docs/ai/playbooks/cloudflare-apps.md`: Create, build, stage, deploy, and
  adopt repo-managed Cloudflare apps.
- `docs/ai/playbooks/cloudflare-email-routing.md`: Declarative Cloudflare Email
  Routing execution workflow.
- `docs/ai/playbooks/cloudflare-state-adoption.md`: Non-DNS Cloudflare
  state-adoption procedure for platform and apps phases.
- `docs/ai/playbooks/nixbot-deploy.md`: Reconstruction spec for `nixbot`
  deployment architecture and bootstrap.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`: Phased `nixbot`
  key-rotation execution workflow.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`: `nixbot` key-generation and
  secret-packaging preparation workflow.

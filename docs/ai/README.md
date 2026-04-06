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
- `docs/ai/lang-patterns/dns.md`: DNS record list ordering (append-only), record
  structure, wiring patterns (tunnel CNAME, external CNAME, A, MX, TXT), merge
  order, and index-shift avoidance rules.
- `docs/ai/lang-patterns/nix.md`: Nix formatting, `inherit` conventions, module
  patterns, attrset style, packaging conventions, flake conventions, and common
  pitfalls.

## Design Patterns

- `docs/ai/design-patterns/dns.md`: Durable DNS design and change-management
  rules for the repo's Cloudflare/OpenTofu stack, including stable record keys,
  phased add/remove sequencing, and recovery guidance after partial applies.
- `docs/ai/design-patterns/tunnels-and-static-origins.md`: Host-level Cloudflare
  Tunnel edge-IP policy, rollout sequencing, and Podman static-site
  materialization rules for directory-backed origins.

## Notes

### Apps

- `docs/ai/notes/apps/default-nix-nix-build-compat-2026-03.md`: Keep package
  `default.nix` files as the canonical definitions and add legacy-compatible
  defaults so they work with both `callPackage` and `nix-build`.
- `docs/ai/notes/apps/flake-architecture-consolidated-2026-03.md`: Canonical
  flake output model, auto-discovery collector, `lib/flake` helpers, hybrid
  package set architecture, wrapper flakes, and the `meta.mainProgram` app
  metadata contract.

### Deployment

- `docs/ai/notes/deployment/deployment-fixes-consolidated-2026-03.md`: Small
  deployment unblockers with lasting operational value.

### Hosts

- `docs/ai/notes/hosts/cloudflare-tunnel-hosts-2026-03.md`: Reusable Cloudflare
  Tunnel host wiring.
- `docs/ai/notes/hosts/desktop-investigations-consolidated-2026-03.md`:
  Consolidated desktop investigations and durable findings.
- `docs/ai/notes/hosts/gap3-gondor-base-image-recreation-investigation-2026-04.md`:
  Root-cause investigation for `pvl-x2` recreating `gap3-gondor` from the
  minimal `gap3-base` image after a flake update, leaving nested `rivendell`
  data intact under `/var/lib` but dropping the takeover runtime.
- `docs/ai/notes/hosts/human-host-docs-add-host-flow-2026-04.md`: Updated
  `docs/hosts.md` so the human add-host flow matches the current Incus parent
  and managed-secret workflow.
- `docs/ai/notes/hosts/pvl-vk-short-host-2026-04.md`: Added `pvl-vk` as a
  shorter nested `pvl-v*` guest alongside `pvl-vkamino`.
- `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md`: Canonical
  reusable Incus guest template, bootstrap flow, naming conventions, and secret
  model.
- `docs/ai/notes/hosts/incus-machines-module-2026-03.md`: Reusable
  `lib/incus/default.nix` NixOS module for declarative incus container
  lifecycle: device sync, config-hash recreate, boot/recreate/preseed tags,
  helper extraction, image handling, GC, and recovery rules.
- `docs/ai/notes/hosts/nested-incus-bastion-pattern-2026-03.md`: Nested Incus
  bastion-host pattern with GPU passthrough, Podman services, an inner guest,
  and `dir` storage to avoid btrfs-on-btrfs.
- `docs/ai/notes/hosts/bash-prompt-exit-status-fix-2026-03.md`: Prompt
  exit-status command substitution was escaped as `\$(...)` during lint cleanup,
  causing the literal text to render in interactive shells.

### Lib

- `docs/ai/notes/lib/lib-broader-review-fixes-2026-03.md`: Broader `lib/` review
  fixes for resume hooks, optional guest Tailscale ownership, Flatpak runtime
  dependencies, and Incus shell-safety and fail-closed guardrails.

### Nixbot

- `docs/ai/notes/nixbot/code-review-and-cleanup-2026-03.md`: Consolidated code
  review, subprocess reduction, dedup, and simplification pass.
- `docs/ai/notes/nixbot/bootstrap-fallback-refresh-and-logging-2026-03.md`:
  Bootstrap-fallback transport retries must not re-probe the primary path, and
  cached bootstrap reuse must not be logged as a fresh forced-command result.
- `docs/ai/notes/nixbot/bootstrap-promotion-and-forced-command-identity-2026-03.md`:
  Preserve the prepared SSH identity for bootstrap probes, and after bootstrap
  key preparation promote back to the primary deploy route before local-build
  `nixos-rebuild` runs.
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
  policy modes, host ordering edges, SSH/runtime guardrails, inline
  `systemd-user-manager` deploy reporting, and result processing architecture.
- `docs/ai/notes/nixbot/dirty-flag-bypass-2026-03.md`: Explicit `--dirty` /
  `NIXBOT_DIRTY` opt-in for bypassing the repo-root cleanliness gate.
- `docs/ai/notes/nixbot/entrypoint-and-packaging-2026-03.md`: Canonical
  entrypoint layout, CLI design, flake packaging model, and wrapper exception.
- `docs/ai/notes/nixbot/activation-context-probe-runtime-path-2026-03.md`: Fix
  the pre-activation machine-age-identity visibility probe to use explicit
  `/run/current-system/sw/bin` runtime paths inside `systemd-run` transient
  units.
- `docs/ai/notes/nixbot/error-handling-and-control-flow-2026-03.md`: Exit status
  preservation, signal handling, phase gating, and Terraform failure
  propagation.
- `docs/ai/notes/nixbot/gcp-platform-phase-disabled-2026-03.md`: Default
  `all`/`tf-platform` deploy phases no longer include `gcp-platform`; run it
  only via explicit `tf/gcp-platform`.
- `docs/ai/notes/nixbot/github-actions-workflow-design-2026-03.md`: GitHub
  Actions workflow design: action input scope, runtime warmup strategy, and thin
  launcher role.
- `docs/ai/notes/nixbot/host-age-identity-single-prep-pass-2026-04.md`: Collapse
  host age identity deploy prep to one activation-context pass that injects only
  when missing or mismatched, and remove the forced reinstall path.
- `docs/ai/notes/nixbot/if-compound-exit-status-swallow-2026-03.md`: Bash
  `if cmd; then ...; fi; rc="$?"` bug in `nixbot` swallowed real failures in
  transport retry, parent readiness, rollback, and report helpers; capture
  failure status in the `else` branch instead.
- `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md`:
  Canonical `nixbot` rotation model, lessons, and operator guardrails.
- `docs/ai/notes/nixbot/known-hosts-isolation-2026-03.md`: Isolate all `nixbot`
  SSH traffic from ambient machine `known_hosts` state by forcing nixbot-managed
  known-hosts files for deploy, proxy, bastion-trigger, and repo-refresh SSH
  paths.
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
- `docs/ai/notes/nixbot/remote-file-install-transport-retries-2026-03.md`: Make
  remote temp-file allocation, file copy, and install steps retry on transport
  resets instead of failing fresh guest deploys immediately.
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
  and `lib/incus/default.nix`.
- `docs/ai/notes/reviews/systemd-user-manager-and-nixbot-cleanup-pass-2026-04.md`:
  Cleanup pass for `systemd-user-manager` and matching `nixbot` report logic,
  including deferred identity restarts, bounded journal polling, and stop-path
  deduplication.
- `docs/ai/notes/reviews/systemd-user-manager-and-nixbot-review-fixes-2026-04.md`:
  Follow-up fixes for review findings in `lib/systemd-user-manager/helper.sh`
  and `pkgs/nixbot/nixbot.sh`, including fatal metadata parse handling,
  Terraform phase failure propagation, and dispatcher report logging cleanup.
- `docs/ai/notes/reviews/nixbot-and-systemd-user-manager-refactor-pass-2026-04.md`:
  Refactor pass covering prepared age-identity caching in `nixbot`, stop-phase
  metadata simplification in `systemd-user-manager`, and small Nix dedup
  cleanups.

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
- `docs/ai/notes/services/systemd-user-manager-deferred-identity-restart-2026-04.md`:
  Defer identity-driven `user@<uid>.service` restarts out of activation and hand
  them off to the post-switch dispatcher through ephemeral `/run` markers.
- `docs/ai/notes/services/systemd-user-manager-bounded-live-journal-and-heartbeats-2026-04.md`:
  Keep live reconciler progress, but bound and rate-limit journal polling and
  add explicit dispatcher heartbeats so slow or quiet journal paths do not look
  like a hung switch.
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
  decisions for `lib/incus/default.nix`, `lib/podman.nix`, and
  `lib/systemd-user-manager.nix`, including the user correction on inactive-unit
  semantics, the Podman `recreateTag` fix, the Incus start failure fix, and the
  `pvl-x2` boot activation root cause.
- `docs/ai/notes/services/module-review-podman-systemd-user-manager-fixes-2026-03.md`:
  Review-driven fixes for generated service-name collisions in `podman` and
  `systemd-user-manager`, plus serialized Podman lifecycle-tag action units.
- `docs/ai/notes/services/openssh-module-centralization-2026-03.md`: Shared
  OpenSSH enablement centralization.
- `docs/ai/notes/services/podman-lifecycle-tag-semantic-stamps-2026-03.md`:
  Podman lifecycle tags now use explicit semantic stamp payloads so `imageTag`,
  `bootTag`, and `recreateTag` only react to declared tag-value changes.
- `docs/ai/notes/services/podman-manager-env-prefix-rename-2026-04.md`: Rename
  podman wrapper-private env vars from `PODMAN_COMPOSE_*` to
  `NIX_PODMAN_COMPOSE_*` so `podman compose` does not treat them as unsupported
  upstream config keys.
- `docs/ai/notes/services/shared-collections-helper-2026-03.md`: Shared
  `lib/flake/utils` helper for reusable pure-Nix collection utilities such as
  duplicate-value detection.
- `docs/ai/notes/services/systemd-user-manager-stateless-simplified-switching-2026-03.md`:
  Final implemented architecture: stateless per-user dispatcher/reconciler
  switching, helper-backed module layout, activation-time old/new diffing,
  boot-safe activation rules, and Podman lifecycle behavior expressed as normal
  units and dependencies.
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
  contract for read-only validation, mode semantics, root-flake checks, and the
  `statix fix` per-target CLI constraint.
- `docs/ai/notes/tooling/flake-check-path-input-fix-2026-03.md`: Lint
  `nix flake check` must `cd` into the sub-flake directory (not use `path:` URI)
  so sibling `path:` inputs resolve via the parent git tree.
- `docs/ai/notes/tooling/pre-push-per-commit-lint-2026-03.md`: Pre-push hook
  replaces pre-commit; lints each commit individually via `--diff --base`.
- `docs/ai/notes/tooling/update-flakes-script-2026-03.md`:
  `scripts/update-flakes.sh` for recursively updating all flake lock files.
- `docs/ai/notes/tooling/tf-selective-cloudflare-state-migration-2026-03.md`:
  Selective two-phase Cloudflare state transfer planning with separate
  import-into-target and remove-from-source command files, including selectors
  for zones, workers, tunnels, and R2 buckets.
- `docs/ai/notes/tooling/rustfmt-treefmt-pkgs-discovery-2026-04.md`: Make
  `nix fmt` run `cargo fmt` generically for tracked Rust crates under `pkgs/`
  through a repo formatter wrapper script.
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

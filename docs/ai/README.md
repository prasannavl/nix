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

## Notes

### Apps

- `docs/ai/notes/apps/default-nix-nix-build-compat-2026-03.md`: Keep package
  `default.nix` files as the canonical definitions and add legacy-compatible
  defaults so they work with both `callPackage` and `nix-build`.
- `docs/ai/notes/apps/flake-architecture-consolidated-2026-03.md`: Canonical
  flake output model, auto-discovery collector, `lib/flake` helpers, hybrid
  package set architecture, and wrapper flakes.
- `docs/ai/notes/apps/cloudflare-apps-remove-openseal-priyasuyash-2026-03.md`:
  Remove the `openseal` and `priyasuyash` Cloudflare apps and clear their
  archive-worker Terraform config.

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
- `docs/ai/notes/hosts/pvl-bash-prompt-exit-status-fix-2026-03.md`: Prompt
  exit-status command substitution was escaped as `\$(...)` during lint cleanup,
  causing the literal text to render in interactive shells.

### Nixbot

- `docs/ai/notes/nixbot/code-review-and-cleanup-2026-03.md`: Consolidated code
  review, subprocess reduction, dedup, and simplification pass.
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
- `docs/ai/notes/nixbot/runtime-temp-suffix-alignment-2026-03.md`: Consolidated
  per-run workspace root for deploy artifacts and detached repo worktrees.
- `docs/ai/notes/nixbot/security-trust-model-2026-03.md`: Bastion-trigger
  operator trust boundary, arbitrary-SHA policy, and relationship between
  worktree isolation and secret access.
- `docs/ai/notes/nixbot/worktree-terraform-lockfile-2026-03.md`: Terraform
  lockfile regression exposed by fresh deploy worktrees and the normalization
  rule for Cloudflare provider locks.

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
- `docs/ai/notes/services/lib-service-module-relocation-2026-03.md`: User-led
  relocation of service-specific helper modules from `lib/` into
  `lib/services/`.
- `docs/ai/notes/services/lib-flake-published-podman-systemd-modules-2026-03.md`:
  Revert `podman` and `systemd-user-manager` to `lib/` and drop the unused
  published flake-module export.
- `docs/ai/notes/services/openssh-module-centralization-2026-03.md`: Shared
  OpenSSH enablement centralization.
- `docs/ai/notes/services/podman-compose-reload-staging-2026-03.md`: Podman
  compose runtime files are copied into working directories and reload now
  performs cleanup plus restaging before `up -d`.
- `docs/ai/notes/services/pvl-x2-nginx-config-bind-mounts-2026-03.md`: `pvl-x2`
  nginx compose config migration from `/home/pvl/tmp/nginx` into repo-managed
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
- `docs/ai/notes/tooling/pre-push-per-commit-lint-2026-03.md`: Pre-push hook
  replaces pre-commit; lints each commit individually via `--diff --base`.
- `docs/ai/notes/tooling/update-flakes-script-2026-03.md`:
  `scripts/update-flakes.sh` for recursively updating all flake lock files.
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

# AI Docs Index

Use this index as the canonical map for `docs/ai/**`.

## Notes

### Apps

- `docs/ai/notes/apps/root-flake-app-exports-and-git-source-2026-03.md`: Root
  flake nested `pkgs.*` export shape, installable naming, and Git snapshot
  behavior.
- `docs/ai/notes/apps/auto-discovered-flake-collectors-2026-03.md`: Shared
  collector behavior for nested `pkgs/` child flakes.

### Deployment

- `docs/ai/notes/deployment/deployment-fixes-consolidated-2026-03.md`: Small
  deployment unblockers with lasting operational value.

### Hosts

- `docs/ai/notes/hosts/cloudflare-tunnel-hosts-2026-03.md`: Reusable Cloudflare
  Tunnel host wiring.
- `docs/ai/notes/hosts/desktop-investigations-consolidated-2026-03.md`:
  Consolidated desktop investigations and durable findings.
- `docs/ai/notes/hosts/incus-base-image-rename-2026-03.md`: Reusable Incus image
  rename from `incus-bootstrap` to `incus-base`.
- `docs/ai/notes/hosts/incus-vm-module-rename-2026-03.md`: Shared Incus guest
  module rename from `incus-machine` to `incus-vm`.
- `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md`: Canonical
  reusable Incus guest template, bootstrap flow, and secret model.

### Nixbot

- `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md`: Canonical
  `nixbot` deploy architecture, runtime contract, and orchestration behavior.
- `docs/ai/notes/nixbot/interrupt-and-phase-short-circuit-2026-03.md`: `Ctrl+C`
  propagation and `--action all` stop-on-first-failure behavior for
  `nixbot-deploy.sh`.
- `docs/ai/notes/nixbot/lint-gating-and-precommit-2026-03.md`: Shared lint
  entrypoint, CI gate, and pre-commit hook decisions.
- `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md`:
  Canonical `nixbot` rotation model, lessons, and operator guardrails.
- `docs/ai/notes/nixbot/nameref-audit-and-fixes-2026-03.md`: Bash nameref
  circular-reference audit and helper-local binding rename strategy for
  `nixbot-deploy.sh`.
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

- `docs/ai/notes/services/bastion-compose-config-centralization-2026-03.md`:
  Bastion compose port and generated-config ownership boundaries.
- `docs/ai/notes/services/bastion-service-migration-consolidated-2026-03.md`:
  Bastion-host service adoption and service-secret migration.
- `docs/ai/notes/services/cloudflare-adoption-and-workers-consolidated-2026-03.md`:
  Canonical Cloudflare adoption status, imported resource summary, and Workers
  convergence decision.
- `docs/ai/notes/services/cloudflare-opentofu-consolidated-2026-03.md`:
  Canonical Cloudflare OpenTofu layout, input model, import rules, and
  source-of-truth boundaries.
- `docs/ai/notes/services/cloudflare-workers-archive-path-fix-2026-03.md`:
  `tf-apps` deploy failure caused by stale `pkgs/cloudflare-workers` paths in
  archive worker tfvars after the repo moved to `pkgs/cloudflare-apps`.
- `docs/ai/notes/services/cloudflare-tunnel-state-adoption-plan-2026-03.md`:
  Tunnel state-adoption plan, ownership-boundary decision, and execution steps.
- `docs/ai/notes/services/docs-sensitive-info-cleanup-2026-03.md`: Documentation
  cleanup rules for sensitive operational details.
- `docs/ai/notes/services/openssh-module-centralization-2026-03.md`: Shared
  OpenSSH enablement centralization.
- `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md`:
  Canonical `services.podmanCompose` and `systemd-user-manager` platform model.

## Playbooks

- `docs/ai/playbooks/ai-docs-reconsolidation.md`: Periodic cleanup workflow for
  reconsolidating `docs/ai/notes`, folding completed `runs` back into notes,
  sanitizing durable identifiers, and refreshing the index.
- `docs/ai/playbooks/cloudflare-email-routing.md`: Declarative Cloudflare Email
  Routing execution workflow.
- `docs/ai/playbooks/cloudflare-state-adoption.md`: Non-DNS Cloudflare
  state-adoption procedure for platform and apps phases.
- `docs/ai/playbooks/cloudflare-apps.md`: Create, build, stage, deploy, and
  adopt repo-managed Cloudflare apps.
- `docs/ai/playbooks/nixbot-deploy.md`: Reconstruction spec for `nixbot`
  deployment architecture and bootstrap.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`: Phased `nixbot`
  key-rotation execution workflow.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`: `nixbot` key-generation and
  secret-packaging preparation workflow.

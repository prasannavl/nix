# AI Docs Index

Use this index as the canonical map for `docs/ai/**`.

## Lang Patterns

- `docs/ai/lang-patterns/common.md`: Cross-language code-practice defaults,
  including the repo line-width recommendation.
- `docs/ai/lang-patterns/bash.md`: Bash structure, shell-safety, and runtime
  shell rules.
- `docs/ai/lang-patterns/markdown.md`: Markdown formatting authority and
  `docs/ai` writing conventions.
- `docs/ai/lang-patterns/dns.md`: DNS record ordering and merge rules.
- `docs/ai/lang-patterns/nix.md`: Nix formatting, module patterns, and flake
  conventions.

## Design Patterns

- `docs/ai/design-patterns/dns.md`: Durable DNS change-management rules for the
  repo Cloudflare stack.
- `docs/ai/design-patterns/tunnels-and-static-origins.md`: Tunnel edge-IP policy
  and static-origin rollout rules.

## Notes

### Apps

- `docs/ai/notes/apps/package-architecture.md`: Canonical package, child-flake,
  manifest, helper, and package-owned service-module rules.

### Hosts

- `docs/ai/notes/hosts/incus-and-host-operations.md`: Canonical Incus guest
  model, host docs structure, tunnel host wiring, and durable host incident
  findings.
- `docs/ai/notes/hosts/pvl-x2-services-layout.md`: Canonical `pvl-x2` service
  module split and aggregation layout.

### Lib

- `docs/ai/notes/lib/library-layout-and-guardrails.md`: Canonical placement
  rules and review guardrails for shared helpers under `lib/`.

### Nixbot

- `docs/ai/notes/nixbot/deploy-system.md`: Canonical `nixbot` deploy, bootstrap,
  SSH, worktree, Terraform, and CI behavior.
- `docs/ai/notes/nixbot/key-rotation.md`: Canonical deploy-key rotation policy
  and guardrails.

### Reviews

- `docs/ai/notes/reviews/architecture-review-followups.md`: Condensed review
  findings and the durable refactoring direction after the follow-up fixes.

### Secrets

- `docs/ai/notes/secrets/topology-and-operations.md`: Canonical secret topology,
  bootstrap order, and managed secret operations.

### Services

- `docs/ai/notes/services/edge-and-platform-infra.md`: Canonical Cloudflare,
  GCP, ingress-metadata, import, and sanitization rules.
- `docs/ai/notes/services/systemd-user-manager.md`: Canonical generation-driven
  `systemd-user-manager` model and dispatcher behavior.
- `docs/ai/notes/services/user-services-platform.md`: Canonical Podman compose,
  nginx, and service-facing ingress policy.

### Tooling

- `docs/ai/notes/tooling/repo-tooling.md`: Canonical Bash entrypoint, lint/fmt,
  package-local verification, and docs-maintenance rules.

## Playbooks

- `docs/ai/playbooks/ai-docs-reconsolidation.md`: Periodic process for merging
  overlapping docs back into a smaller canonical set.
- `docs/ai/playbooks/cloudflare-apps.md`: Reusable Cloudflare apps workflow.
- `docs/ai/playbooks/cloudflare-email-routing.md`: Reusable Cloudflare email
  routing workflow.
- `docs/ai/playbooks/cloudflare-state-adoption.md`: Reusable Cloudflare import
  and adoption workflow.
- `docs/ai/playbooks/nixbot-deploy.md`: Reusable nixbot deploy workflow.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`: Phased nixbot key
  rotation execution procedure.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`: Nixbot key generation and
  prep procedure.

## Runs

- `docs/ai/runs/`: Temporary staging area for active multi-step or multi-agent
  work. Keep it empty when there is no active staged run.

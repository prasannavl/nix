# AI Docs Index

Use this index as the canonical map for `docs/ai/**`.

## Notes

### Deployment

- `docs/ai/notes/deployment/deployment-fixes-consolidated-2026-03.md`:
  Small deployment unblockers with lasting operational value.

### Hosts

- `docs/ai/notes/hosts/cloudflare-tunnel-hosts-2026-03.md`:
  Reusable Cloudflare Tunnel host wiring.
- `docs/ai/notes/hosts/desktop-investigations-consolidated-2026-03.md`:
  Consolidated desktop investigations and durable findings.
- `docs/ai/notes/hosts/incus-guest-ollama-amd-gpu-2026-03.md`:
  AMD GPU passthrough model for an Incus Ollama guest.
- `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md`:
  Canonical reusable Incus guest template and secret model.

### Nixbot

- `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md`:
  Canonical `nixbot` deploy architecture and orchestration behavior.
- `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md`:
  Canonical `nixbot` rotation model, lessons, and operator guardrails.

### Secrets

- `docs/ai/notes/secrets/age-secrets-clean-flag-2026-03.md`:
  Managed secret cleanup behavior for `scripts/age-secrets.sh`.
- `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md`:
  Canonical secret topology, trust domains, and bootstrap order.

### Services

- `docs/ai/notes/services/bastion-service-migration-consolidated-2026-03.md`:
  Bastion-host service adoption and service-secret migration.
- `docs/ai/notes/services/cloudflare-adoption-and-workers-consolidated-2026-03.md`:
  Canonical Cloudflare adoption status, imported resource summary, and Workers
  convergence decision.
- `docs/ai/notes/services/cloudflare-opentofu-consolidated-2026-03.md`:
  Canonical Cloudflare OpenTofu layout, input model, and source-of-truth rules.
- `docs/ai/notes/services/docs-sensitive-info-cleanup-2026-03.md`:
  Documentation cleanup rules for sensitive operational details.
- `docs/ai/notes/services/openssh-module-centralization-2026-03.md`:
  Shared OpenSSH enablement centralization.
- `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md`:
  Canonical `services.podmanCompose` and `systemd-user-manager` platform model.
- `docs/ai/notes/services/public-dns-test-a-record-2026-03.md`:
  Test public DNS record addition in the Cloudflare DNS stack.

## Playbooks

- `docs/ai/playbooks/ai-docs-reconsolidation.md`:
  Periodic cleanup workflow for reconsolidating `docs/ai/notes`, folding
  completed `runs` back into notes, and refreshing the index.
- `docs/ai/playbooks/cloudflare-email-routing.md`:
  Declarative Cloudflare Email Routing execution workflow.
- `docs/ai/playbooks/cloudflare-state-adoption.md`:
  Non-DNS Cloudflare state-adoption procedure for platform and apps phases.
- `docs/ai/playbooks/cloudflare-workers.md`:
  Create, deploy, and adopt repo-managed Cloudflare Workers.
- `docs/ai/playbooks/nixbot-deploy.md`:
  Reconstruction spec for `nixbot` deployment architecture and bootstrap.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`:
  Phased `nixbot` key-rotation execution workflow.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`:
  `nixbot` key-generation and secret-packaging preparation workflow.

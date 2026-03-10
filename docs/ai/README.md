# AI Docs Index

- `docs/ai/playbooks/nixbot-deploy.md`: Reconstruction spec for nixbot
  deployment architecture and bootstrap behavior.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`: Agent-executable phased
  key-rotation playbook with mandatory confirmation gates.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`: Agent-executable
  key-generation and secret-packaging playbook for rotation prep.
- `docs/ai/notes/deployment/deployment-fixes-consolidated-2026-03.md`: Small
  deployment unblockers, currently the `incus` `checkPhase` SIGBUS mitigation.
- `docs/ai/notes/hosts/llmug-rivendell-ollama-amd-on-pvl-x2.md`: Reconfigured
  `llmug-rivendell` Ollama GPU access from NVIDIA CDI to AMD (`/dev/dri` +
  `/dev/kfd`) for deployment on `pvl-x2`.
- `docs/ai/notes/hosts/llmug-rivendell-tailscale-login-2026-03.md`: Added
  `llmug-rivendell` Tailscale autologin wiring via an agenix-managed auth key at
  `data/secrets/tailscale/llmug-rivendell.key.age`.
- `docs/ai/notes/hosts/pvl-a1-desktop-investigations-consolidated-2026-03.md`:
  Consolidated `pvl-a1` desktop investigation state for suspend watchdogs, GNOME
  idle inhibition, and `amdxdna` mismatch handling.
- `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md`: Consolidated
  `nixbot` deploy architecture, bootstrap flow, machine-age identity model,
  host-key handling, and GitHub Actions connectivity state.
- `docs/ai/notes/nixbot/deploy-log-formatting-2026-03.md`: Added simple
  phase/host headers to `nixbot-deploy.sh` logs for clearer build, snapshot,
  deploy, and rollback demarcation.
- `docs/ai/notes/nixbot/deploy-order-deps-2026-03.md`: Dependency-aware host
  ordering for `nixbot` builds/deploys via `hosts.nixbot.<host>.deps`.
- `docs/ai/notes/nixbot/deploy-snapshot-fallback-2026-03.md`: Best-effort
  upfront generation snapshots with dependency-wave retries before deploy.
- `docs/ai/notes/nixbot/bastion-reexec-checked-out-script-2026-03.md`: Optional
  bastion re-exec into the checked-out repo script for `--sha` runs.
- `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md`:
  Consolidated `nixbot` rotation model, legacy-host recovery lessons, operator
  guardrails, and the playbook relationship.
- `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md`:
  Consolidated `services.podmanCompose` and `systemd-user-manager` platform
  model, including file materialization, `envSecrets`, and unit lifecycle.
- `docs/ai/notes/services/pvl-x2-compose-config-centralization-2026-03.md`:
  Centralized `pvl-x2` compose port metadata in per-instance Nix definitions and
  reused it for compose generation and firewall rules.
- `docs/ai/notes/services/pvl-x2-service-migration-consolidated-2026-03.md`:
  Consolidated `pvl-x2` service adoption into repo-managed compose stacks and
  the aligned service-secret migration.

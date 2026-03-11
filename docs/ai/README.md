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
- `docs/ai/notes/hosts/incus-bootstrap-deploy-flow-2026-03.md`: Replaced the
  host-specific `llmug-rivendell` Incus image with a reusable generic bootstrap
  image under `lib/images` and taught `nixbot` to auto-include dependency hosts
  for deploys.
- `docs/ai/notes/hosts/llmug-rivendell-tailscale-login-2026-03.md`: Added
  `llmug-rivendell` Tailscale autologin wiring via an agenix-managed secret at
  `data/secrets/tailscale/llmug-rivendell.key.age`, now used for OAuth-based
  tagged login.
- `docs/ai/notes/hosts/pvl-a1-desktop-investigations-consolidated-2026-03.md`:
  Consolidated `pvl-a1` desktop investigation state for suspend watchdogs, GNOME
  idle inhibition, and `amdxdna` mismatch handling.
- `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md`: Consolidated
  `nixbot` deploy architecture, bastion/bootstrap trust boundaries,
  dependency-wave orchestration, snapshot semantics, status/logging rules, and
  GitHub Actions connectivity state.
- `docs/ai/notes/nixbot/nixbot-home-dir-perms-2026-03.md`: Ensured
  `/var/lib/nixbot` is created as a usable `nixbot` home directory on all
  hosts so remote snapshot/deploy probes do not emit home-directory permission
  errors.
- `docs/ai/notes/nixbot/deploy-noninteractive-tty-fallback-2026-03.md`: Fixed
  `nixbot` deploy's `/dev/tty` probe so host age identity injection works in
  non-interactive service/wrapper runs.
- `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md`:
  Consolidated `nixbot` rotation model, legacy-host recovery lessons, operator
  guardrails, and the playbook relationship.
- `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md`:
  Consolidated `services.podmanCompose` and `systemd-user-manager` platform
  model, including file materialization, `envSecrets`, and unit lifecycle.
- `docs/ai/notes/services/opentofu-cloudflare-dns-2026-03.md`: Replaced the
  experimental Nix-based Cloudflare DNS approach with a root `tf/` OpenTofu
  stack using the official Cloudflare provider, plus a `tf/`-scoped GitHub
  Actions workflow for validation and apply.
- `docs/ai/notes/services/pvl-x2-compose-config-centralization-2026-03.md`:
  Centralized `pvl-x2` compose port metadata in per-instance Nix definitions and
  reused it for compose generation and firewall rules.
- `docs/ai/notes/services/pvl-x2-service-migration-consolidated-2026-03.md`:
  Consolidated `pvl-x2` service adoption into repo-managed compose stacks and
  the aligned service-secret migration.

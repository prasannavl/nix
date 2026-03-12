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
  an Incus guest's Ollama GPU access from NVIDIA CDI assumptions to AMD
  passthrough (`/dev/dri` + `/dev/kfd`) on its parent host.
- `docs/ai/notes/hosts/incus-bootstrap-deploy-flow-2026-03.md`: Replaced a
  host-specific Incus image with a reusable generic bootstrap image under
  `lib/images` and taught `nixbot` to auto-include dependency hosts for
  deploys.
- `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md`: Canonical
  reusable Incus guest template and secret model for future guests.
- `docs/ai/notes/hosts/llmug-rivendell-tailscale-login-2026-03.md`: Added
  reusable guest Tailscale autologin wiring via an agenix-managed secret in the
  standard `data/secrets/tailscale/<host>.key.age` location.
- `docs/ai/notes/hosts/pvl-a1-desktop-investigations-consolidated-2026-03.md`:
  Consolidated a desktop host investigation covering suspend watchdogs, GNOME
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
  stack using the official Cloudflare provider, executed through
  `scripts/nixbot-deploy.sh --action tf` locally, via bastion, or from the
  existing `nixbot` GitHub workflow.
- `docs/ai/notes/services/docs-sensitive-info-cleanup-2026-03.md`: Removed
  concrete domains and a personal repository SSH URL from documentation so
  those values remain in config and operational state instead of docs.
- `docs/ai/notes/services/opentofu-cloudflare-tf-secrets-2026-03.md`: Added
  repo-managed Cloudflare and R2 runtime secrets for `--action tf`, decrypted
  on demand by `scripts/nixbot-deploy.sh` from
  `data/secrets/cloudflare/*.key.age` when environment variables are
  absent.
- `docs/ai/notes/services/opentofu-cloudflare-sensitive-tfvars-2026-03.md`:
  Split Cloudflare DNS Terraform inputs into public-safe and encrypted
  sensitive layers, merged at runtime by `scripts/nixbot-deploy.sh --action tf`.
- `docs/ai/notes/nixbot/runtime-shell-consolidation-2026-03.md`: Standardized
  `scripts/nixbot-deploy.sh` to re-exec inside a single `nix shell` runtime so
  deploy, bastion-trigger, and Terraform paths use the same packaged command
  set instead of mixing host-installed tools with ad hoc `nix shell` calls.
- `docs/ai/notes/secrets/age-secrets-clean-flag-2026-03.md`: Added
  `scripts/age-secrets.sh clean` / `-c` to remove decrypted plaintext siblings
  of managed `*.age` secrets without touching unmanaged files.
- `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md`:
  Canonical secret-topology note covering per-machine age identities, bastion
  ingress and deploy identities, service secret delivery, and clean-room
  bootstrap order.
- `docs/ai/notes/services/pvl-x2-compose-config-centralization-2026-03.md`:
  Centralized bastion-host compose port metadata in per-instance Nix
  definitions and reused it for compose generation and firewall rules.
- `docs/ai/notes/services/pvl-x2-service-migration-consolidated-2026-03.md`:
  Consolidated bastion-host service adoption into repo-managed compose stacks
  and the aligned service-secret migration.

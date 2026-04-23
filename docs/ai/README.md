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
- `docs/ai/design-patterns/podman-compose-instance.md`: Canonical attribute
  ordering for `services.podmanCompose.<stack>.instances.<name>` declarations.
- `docs/ai/design-patterns/tunnels-and-static-origins.md`: Tunnel edge-IP policy
  and static-origin rollout rules.

## Notes

### Apps

- `docs/ai/notes/apps/package-architecture.md`: Canonical package, child-flake,
  manifest, helper, and package-owned service-module rules.
- `docs/ai/notes/apps/vscode-libsecret-password-store-2026-04.md`: Records the
  user VS Code wrapper choice that forces Code to use libsecret for password
  storage.

### Hosts

- `docs/ai/notes/hosts/incus-and-host-operations.md`: Canonical Incus guest
  model, host docs structure, tunnel host wiring, and durable host incident
  findings.
- `docs/ai/notes/hosts/pvl-niri-desktop-2026-04.md`: Records the `pvl` Niri
  desktop user-module shape, session services, cursor handling, SSH socket, and
  portal choices.
- `docs/ai/notes/hosts/pvl-noctalia-module-2026-04.md`: Records the dedicated
  `users/pvl/noctalia/` module that keeps Noctalia runtime config in Home
  Manager options, can embed custom colorscheme payloads directly in Nix, and
  lets plugin payloads come from upstream sources.
- `docs/ai/notes/hosts/pvl-noctalia-ipc-launcher-2026-04.md`: Records the
  Noctalia launcher IPC lookup failure caused by Qt platform selection during
  quickshell display matching and the durable `QT_QPA_PLATFORM=wayland` fix for
  Sway and Niri keybindings.
- `docs/ai/notes/hosts/pvl-wm-wayland-env-policy-2026-04.md`: Records the move
  away from session-wide Wayland-preference environment exports for Sway and
  Niri, keeping per-app wrappers as the preferred fallback when specific apps
  need backend coercion.
- `docs/ai/notes/hosts/pvl-shared-screenshot-keybindings-2026-04.md`: Records
  the screenshot keybinding layout across Sway, Niri, and GNOME plus the current
  split between `Super+X` on tiling WMs and `Super+C` on GNOME.
- `docs/ai/notes/hosts/pvl-wm-session-services-2026-04.md`: Records the shared
  `pvl` tiling-WM session services used by both Sway and Niri.
- `docs/ai/notes/hosts/pvl-x2-sway-drm-device-2026-04.md`: Records the PCI
  backed DRM alias choice for `pvl-x2` and `pvl-a1` compositor startup instead
  of numeric `/dev/dri/cardN` paths or vendor-only aliases.
- `docs/ai/notes/hosts/pvl-a1-sway-gdm-session-2026-04.md`: Records the `pvl-a1`
  Sway launch split between the GDM-owned system wrapper and the Home Manager
  user config.
- `docs/ai/notes/hosts/pvl-a1-sway-fractional-scale-blur-2026-04.md`: Records
  the `pvl-a1` Sway fractional-scale blur root cause and the shared
  output-default fix.
- `docs/ai/notes/hosts/pvl-a1-sway-client-scaling-2026-04.md`: Records the
  remaining `pvl-a1` Sway blur as a client-rendering-path issue and the
  session-wide Wayland-backend preference fix.
- `docs/ai/notes/hosts/pvl-a1-sway-xdpw-window-chooser-2026-04.md`: Records the
  `pvl-a1` Sway xdg-desktop-portal-wlr window chooser failure, the effective
  config ownership, and the durable JSON-parsing fix.
- `docs/ai/notes/hosts/pvl-a1-niri-portal-screencast-2026-04.md`: Records the
  `pvl-a1` Niri Chrome/Google Meet screen-share regression caused by globally
  replacing the portal core with git `main` while using packaged GNOME portal
  backends.
- `docs/ai/notes/hosts/pvl-a1-sway-ssh-agent-2026-04.md`: Records the `pvl-a1`
  Sway SSH-agent choice and GPG-agent session socket wiring.
- `docs/ai/notes/hosts/pvl-dbus-broker-policy-2026-04.md`: Records the DBus
  broker policy cleanup for Debian-style `sudo` and `pulse` account references
  exposed by the broker migration.
- `docs/ai/notes/hosts/pvl-x2-services-layout.md`: Canonical `pvl-x2` service
  module split and aggregation layout.
- `docs/ai/notes/hosts/pvl-x2-incus-switch-image-restart-2026-04.md`: Records
  the `pvl-x2` Incus deploy regression where local image store-path churn
  restarted declared guest lifecycle units during normal `switch`, plus the
  durable explicit-trigger fix.

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
- `docs/ai/notes/services/cloudflare-dns-stable-record-keys-2026-04.md`: Records
  the DNS migration from positional Terraform addresses to explicit stable
  record keys, plus remaining positional Cloudflare list inputs.
- `docs/ai/notes/services/podman-data-dir-ownership-2026-04.md`: Records the
  standard `dirs`/container-scope ownership model for service-local Podman data
  directories plus the shared bootstrap helper pattern for external data roots.
- `docs/ai/notes/services/postgres-port-publishing.md`: Durable note for the
  `pvl-x2` Postgres Podman Compose host-port publishing failure and workaround.
- `docs/ai/notes/services/systemd-user-manager.md`: Canonical generation-driven
  `systemd-user-manager` model and dispatcher behavior.
- `docs/ai/notes/services/home-manager-systemd-user-manager-ordering-2026-04.md`: Records the false-positive lingering-user restart on `pvl-x2`, the Home Manager versus dispatcher race during dconf activation, and the durable identity-stamp plus unit-ordering fix.
- `docs/ai/notes/services/user-services-platform.md`: Canonical Podman compose,
  nginx, and service-facing ingress policy.

### Tooling

- `docs/ai/notes/tooling/puppeteer-chrome-nix-ld-2026-04.md`: Records the
  `nix-ld` runtime-library fix for local Puppeteer Chrome binaries on NixOS.
- `docs/ai/notes/tooling/pvl-vscode-direnv-devshells-2026-04.md`: Records the
  move from `arrterian.nix-env-selector` to `mkhl.direnv` plus the root flake
  `devShells.default`/`devShells.full` abstraction in
  `lib/flake/dev-shells.nix`.
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

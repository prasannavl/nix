# AI Docs Index

Use this index as the canonical map for `docs/ai/**`.

## Lang Patterns

- `docs/ai/lang-patterns/common.md`: Cross-language code-practice defaults.
- `docs/ai/lang-patterns/bash.md`: Bash structure, shell-safety, and runtime
  shell rules.
- `docs/ai/lang-patterns/markdown.md`: Markdown formatter and `docs/ai` writing
  rules.
- `docs/ai/lang-patterns/dns.md`: DNS record ordering and merge rules.
- `docs/ai/lang-patterns/nix.md`: Nix formatting, module, and flake conventions.

## Design Patterns

- `docs/ai/design-patterns/dns.md`: Durable DNS change-management rules for the
  repo Cloudflare stack.
- `docs/ai/design-patterns/external-service-secret-placement.md`: Stack-scoped
  external-provider secret placement under
  `data/secrets/<stack>/ext/<provider>`.
- `docs/ai/design-patterns/podman-compose-instance.md`: Canonical attribute
  ordering for `services.podmanCompose.<stack>.instances.<name>` declarations
  and direct `/nix/store` mounts for read-only package content.
- `docs/ai/design-patterns/prefer-defaults.md`: Prefer upstream defaults for
  infra and runtime knobs unless there is a demonstrated reason to override.
- `docs/ai/design-patterns/stack-first-environments.md`: Stack-first
  environment, service-registry, package-boundary, and deferred-consumer rules.
- `docs/ai/design-patterns/tunnels-and-static-origins.md`: Tunnel edge-IP policy
  and static-origin rollout rules.

## Notes

### Apps

- `docs/ai/notes/apps/package-architecture.md`: Canonical package, child-flake,
  package-owned module, service-module helper, and repo stack rules.
- `docs/ai/notes/apps/tailscale-upstream-package-2026-05.md`: Records the
  upstream Tailscale source-build override, overlay alias, and NixOS module
  consumption contract.
- `docs/ai/notes/apps/vscode-libsecret-password-store-2026-04.md`: Records the
  user VS Code wrapper choice that forces Code to use libsecret for password
  storage.

### Hosts

- `docs/ai/notes/hosts/incus-and-host-operations.md`: Canonical Incus guest
  model, host docs structure, tunnel host wiring, LXC networking, and durable
  host incident findings.
- `docs/ai/notes/hosts/incus-remote-delegation-2026-05.md`: Records the remote
  `services.incusMachines` target mode and the first `pvl-x2` delegation into
  `pvl-vlab-1`, where lifecycle commands create instances on the parent daemon.
- `docs/ai/notes/hosts/incus-gpu-device-helpers-2026-04.md`: Records the shared
  explicit DRM/KFD Incus device helper shape for reusable card/render-number and
  group-aware passthrough declarations.
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
- `docs/ai/notes/hosts/pvl-wm-idle-lock-2026-04.md`: Records the shared
  `swayidle` battery and AC lock policy for Sway and Niri plus the existing
  manual lock shortcuts.
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
- `docs/ai/notes/hosts/pvl-a1-inline-compose-2026-04.md`: Records the migration
  of the remaining `pvl-a1` service-local `docker.compose.yaml` files into
  inline Nix compose sources while retaining staged `.env` files.
- `docs/ai/notes/hosts/pvl-a1-gcloud-log-streaming-2026-04.md`: Records the
  `pvl-a1` switch from the base `google-cloud-sdk` package to a
  `withExtraComponents` build that includes `log-streaming` for Cloud Run log
  tailing.
- `docs/ai/notes/hosts/pvl-a1-incus-client-cert-2026-05.md`: Records the
  `pvl-a1` pinned Incus client certificates and admin-only encrypted private
  keys used for deterministic TLS client login, the matching TCP `8443` firewall
  opening, and the current default-project-only Incus shape with just the
  unrestricted `pvl` client certificate declared.
- `docs/ai/notes/hosts/pvl-dbus-broker-policy-2026-04.md`: Records the DBus
  broker policy cleanup for Debian-style `sudo` and `pulse` account references
  exposed by the broker migration.
- `docs/ai/notes/hosts/pvl-disko-install-layout-2026-05.md`: Records the disko
  automated-install layout for `pvl-x2` and `pvl-a1`, including target disk IDs,
  pinned partition identities, LUKS, and Btrfs subvolumes.
- `docs/ai/notes/hosts/pvl-x2-services-layout.md`: Canonical `pvl-x2` service
  module split and aggregation layout.
- `docs/ai/notes/hosts/pvl-x2-inline-compose-2026-04.md`: Records the migration
  of `pvl-x2` service-local `docker.compose.yaml` files into inline Nix compose
  sources, with Immich helper YAML retained and Zulip kept as a disabled inline
  reference.
- `docs/ai/notes/hosts/pvl-x2-incus-switch-image-restart-2026-04.md`: Records
  the `pvl-x2` Incus deploy regression where local image store-path churn
  restarted declared guest lifecycle units during normal `switch`, plus the
  durable explicit-trigger fix.
- `docs/ai/notes/hosts/pvl-x2-incus-project-storage-pools-2026-05.md`: Records
  the separate Btrfs storage pools for the `pvl`, `abird`, `abird-stage`, and
  `abird-dev` Incus projects on `pvl-x2`.

### Lib

- `docs/ai/notes/lib/library-layout-and-guardrails.md`: Canonical placement
  rules and review guardrails for shared helpers under `lib/`.
- `docs/ai/notes/lib/podman-compose-staged-file-ownership-2026-04.md`: Records
  per-entry `mode`/`user`/`group`/`scope` plus `dirs.once` behavior for staged
  Podman Compose directories, files, and file secrets.

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
  directories plus absolute `dirs` entries for external data roots.
- `docs/ai/notes/services/postgres-port-publishing.md`: Durable note for the
  `pvl-x2` Postgres Podman Compose host-port publishing failure and workaround.
- `docs/ai/notes/services/openwebui-ollama-host-alias-firewall-2026-04.md`:
  Records the `pvl-a1` versus `pvl-x2` Open WebUI/Ollama difference as a host
  firewall policy issue on published port `11434`, not a compose-network issue.
- `docs/ai/notes/services/ollama-context-length-128k-2026-04.md`: Records the
  `pvl-a1` decision to set `OLLAMA_CONTEXT_LENGTH=131072` on both Ollama service
  instances so Open WebUI prompts do not get truncated at the prior 4k effective
  context limit.
- `docs/ai/notes/services/ollama-shared-models-dir-pvl-a1-2026-04.md`: Records
  the `pvl-a1` decision to share one staged Ollama models directory across the
  ROCm and NVIDIA instances while keeping separate per-instance Ollama homes.
- `docs/ai/notes/services/systemd-user-manager.md`: Canonical generation-driven
  `systemd-user-manager` model and dispatcher behavior.
- `docs/ai/notes/services/home-manager-systemd-user-manager-ordering-2026-04.md`:
  Records the false-positive lingering-user restart on `pvl-x2`, the Home
  Manager versus dispatcher race during dconf activation, and the durable
  identity-stamp plus unit-ordering fix.
- `docs/ai/notes/services/user-services-platform.md`: Canonical Podman compose,
  nginx, ingress, and soft backend-dependency policy.

### Tooling

- `docs/ai/notes/tooling/ai-nix-evaluation-source-refs-2026-05.md`: Records the
  AI-agent validation rule to avoid explicit `path:` flake refs and prefer `.`,
  absolute repo paths, or intentional `git+file:///...` refs.
- `docs/ai/notes/tooling/data-migrator-incus-drain-2026-05.md`: Records the
  generic `data-migrator` port and the intentionally Incus-LXC-only drain
  semantics.
- `docs/ai/notes/tooling/gap3-post-87a57ae-port-2026-05.md`: Tracks the
  selective post-`87a57ae` `gap3/master` port, including per-commit port,
  equivalent, and skip decisions.
- `docs/ai/notes/tooling/gap3-post-8314da5b-port-2026-05.md`: Tracks the
  selective post-`8314da5b` `gap3/master` port plan, per-commit dispositions,
  staged foundations, and skipped project-specific work.
- `docs/ai/notes/tooling/gap3-unit4-stack-registry-foundation-2026-05.md`:
  Records the Unit 4 stack/service-registry/package helper foundation port and
  the Abird-specific, secret-policy, nginx-composer, and mail-directory
  deferrals.
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
- `docs/ai/playbooks/gcp-ad-hoc-nixos-bootstrap.md`: Procedure for creating ad
  hoc GCP bootstrap VMs and converting them to NixOS with repo or generic host
  configs.
- `docs/ai/playbooks/nixbot-deploy.md`: Reusable nixbot deploy workflow.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`: Phased nixbot key
  rotation execution procedure.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`: Nixbot key generation and
  prep procedure.

## Runs

- `docs/ai/runs/`: Temporary staging area for active multi-step or multi-agent
  work. Keep it empty when there is no active staged run.

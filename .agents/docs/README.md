# AI Docs Index

Use this index as the canonical map for `.agents/docs/**`.

## Lang Patterns

- `.agents/docs/lang-patterns/common.md`: Cross-language code-practice defaults.
- `.agents/docs/lang-patterns/bash.md`: Bash structure, shell-safety, and
  runtime shell rules.
- `.agents/docs/lang-patterns/markdown.md`: Markdown formatter and
  `.agents/docs` writing rules.
- `.agents/docs/lang-patterns/dns.md`: DNS record ordering and merge rules.
- `.agents/docs/lang-patterns/nix.md`: Nix formatting, module, and flake
  conventions.

## Design Patterns

- `.agents/docs/design-patterns/dns.md`: Durable DNS change-management rules for
  the repo Cloudflare stack.
- `.agents/docs/design-patterns/external-service-secret-placement.md`:
  Stack-scoped external-provider secret placement under
  `data/secrets/<stack>/ext/<provider>`.
- `.agents/docs/design-patterns/podman-compose-instance.md`: Canonical attribute
  ordering for `services.podmanCompose.<stack>.instances.<name>` declarations
  and direct `/nix/store` mounts for read-only package content.
- `.agents/docs/design-patterns/prefer-defaults.md`: Prefer upstream defaults
  for infra and runtime knobs unless there is a demonstrated reason to override.
- `.agents/docs/design-patterns/stack-first-environments.md`: Stack-first
  environment, service-registry, package-boundary, and deferred-consumer rules.
- `.agents/docs/design-patterns/tunnels-and-static-origins.md`: Tunnel edge-IP
  policy and static-origin rollout rules.

## Notes

### Apps

- `.agents/docs/notes/apps/package-architecture.md`: Canonical package,
  child-flake, package-owned module, service-module helper, and repo stack
  rules.
- `.agents/docs/notes/apps/tailscale-upstream-package-2026-05.md`: Records the
  upstream Tailscale source-build override, overlay alias, and NixOS module
  consumption contract.
- `.agents/docs/notes/apps/vscode-libsecret-password-store-2026-04.md`: Records
  the user VS Code wrapper choice that forces Code to use libsecret for password
  storage.

### Hosts

- `.agents/docs/notes/hosts/incus-and-host-operations.md`: Canonical Incus guest
  model, host docs structure, tunnel host wiring, LXC networking, and durable
  host incident findings.
- `.agents/docs/notes/hosts/incus-remote-delegation-2026-05.md`: Records the
  remote `services.incusMachines` target mode and the first `pvl-x2` delegation
  into `pvl-vlab-1`, where lifecycle commands create instances on the parent
  daemon.
- `.agents/docs/notes/hosts/incus-gpu-device-helpers-2026-04.md`: Records the
  shared explicit DRM/KFD Incus device helper shape for reusable
  card/render-number and group-aware passthrough declarations.
- `.agents/docs/notes/hosts/pvl-niri-desktop-2026-04.md`: Records the `pvl` Niri
  desktop user-module shape, session services, cursor handling, SSH socket, and
  portal choices.
- `.agents/docs/notes/hosts/pvl-noctalia-module-2026-04.md`: Records the
  dedicated `users/pvl/noctalia/` module that keeps Noctalia runtime config in
  Home Manager options, can embed custom colorscheme payloads directly in Nix,
  and lets plugin payloads come from upstream sources.
- `.agents/docs/notes/hosts/pvl-noctalia-ipc-launcher-2026-04.md`: Records the
  Noctalia launcher IPC lookup failure caused by Qt platform selection during
  quickshell display matching and the durable `QT_QPA_PLATFORM=wayland` fix for
  Sway and Niri keybindings.
- `.agents/docs/notes/hosts/pvl-wm-wayland-env-policy-2026-04.md`: Records the
  move away from session-wide Wayland-preference environment exports for Sway
  and Niri, keeping per-app wrappers as the preferred fallback when specific
  apps need backend coercion.
- `.agents/docs/notes/hosts/pvl-shared-screenshot-keybindings-2026-04.md`:
  Records the screenshot keybinding layout across Sway, Niri, and GNOME plus the
  current split between `Super+X` on tiling WMs and `Super+C` on GNOME.
- `.agents/docs/notes/hosts/pvl-wm-idle-lock-2026-04.md`: Records the shared
  `swayidle` battery and AC lock policy for Sway and Niri plus the existing
  manual lock shortcuts.
- `.agents/docs/notes/hosts/pvl-wm-session-services-2026-04.md`: Records the
  shared `pvl` tiling-WM session services used by both Sway and Niri.
- `.agents/docs/notes/hosts/pvl-x2-sway-drm-device-2026-04.md`: Records the PCI
  backed DRM alias choice for `pvl-x2` and `pvl-a1` compositor startup instead
  of numeric `/dev/dri/cardN` paths or vendor-only aliases.
- `.agents/docs/notes/hosts/pvl-a1-sway-gdm-session-2026-04.md`: Records the
  `pvl-a1` Sway launch split between the GDM-owned system wrapper and the Home
  Manager user config.
- `.agents/docs/notes/hosts/pvl-a1-sway-fractional-scale-blur-2026-04.md`:
  Records the `pvl-a1` Sway fractional-scale blur root cause and the shared
  output-default fix.
- `.agents/docs/notes/hosts/pvl-a1-sway-client-scaling-2026-04.md`: Records the
  remaining `pvl-a1` Sway blur as a client-rendering-path issue and the
  session-wide Wayland-backend preference fix.
- `.agents/docs/notes/hosts/pvl-a1-sway-xdpw-window-chooser-2026-04.md`: Records
  the `pvl-a1` Sway xdg-desktop-portal-wlr window chooser failure, the effective
  config ownership, and the durable JSON-parsing fix.
- `.agents/docs/notes/hosts/pvl-a1-niri-portal-screencast-2026-04.md`: Records
  the `pvl-a1` Niri Chrome/Google Meet screen-share regression caused by
  globally replacing the portal core with git `main` while using packaged GNOME
  portal backends.
- `.agents/docs/notes/hosts/pvl-a1-sway-ssh-agent-2026-04.md`: Records the
  `pvl-a1` Sway SSH-agent choice and GPG-agent session socket wiring.
- `.agents/docs/notes/hosts/pvl-a1-inline-compose-2026-04.md`: Records the
  migration of the remaining `pvl-a1` service-local `docker.compose.yaml` files
  into inline Nix compose sources while retaining staged `.env` files.
- `.agents/docs/notes/hosts/pvl-a1-gcloud-log-streaming-2026-04.md`: Records the
  `pvl-a1` switch from the base `google-cloud-sdk` package to a
  `withExtraComponents` build that includes `log-streaming` for Cloud Run log
  tailing.
- `.agents/docs/notes/hosts/pvl-a1-incus-client-cert-2026-05.md`: Records the
  `pvl-a1` pinned Incus client certificates and admin-only encrypted private
  keys used for deterministic TLS client login, the matching TCP `8443` firewall
  opening, and the current default-project-only Incus shape with just the
  unrestricted `pvl` client certificate declared.
- `.agents/docs/notes/hosts/pvl-dbus-broker-policy-2026-04.md`: Records the DBus
  broker policy cleanup for Debian-style `sudo` and `pulse` account references
  exposed by the broker migration.
- `.agents/docs/notes/hosts/pvl-disko-install-layout-2026-05.md`: Records the
  disko automated-install layout for `pvl-x2` and `pvl-a1`, including target
  disk IDs, pinned partition identities, LUKS, and Btrfs subvolumes.
- `.agents/docs/notes/hosts/pvl-x2-services-layout.md`: Canonical `pvl-x2`
  service module split and aggregation layout.
- `.agents/docs/notes/hosts/pvl-x2-inline-compose-2026-04.md`: Records the
  migration of `pvl-x2` service-local `docker.compose.yaml` files into inline
  Nix compose sources, with Immich helper YAML retained and Zulip kept as a
  disabled inline reference.
- `.agents/docs/notes/hosts/pvl-x2-incus-switch-image-restart-2026-04.md`:
  Records the `pvl-x2` Incus deploy regression where local image store-path
  churn restarted declared guest lifecycle units during normal `switch`, plus
  the durable explicit-trigger fix.
- `.agents/docs/notes/hosts/pvl-x2-incus-project-storage-pools-2026-05.md`:
  Records the separate Btrfs storage pools for the `pvl`, `abird`,
  `abird-stage`, and `abird-dev` Incus projects on `pvl-x2`.

### Lib

- `.agents/docs/notes/lib/library-layout-and-guardrails.md`: Canonical placement
  rules and review guardrails for shared helpers under `lib/`.
- `.agents/docs/notes/lib/incus-podman-lifecycle-policy-redesign-2026-06.md`:
  Records the Incus, Podman Compose, and `systemd-user-manager` lifecycle policy
  redesign, rollout, and post-rollout cleanup model.
- `.agents/docs/notes/lib/installer-to-disk-mbr-persistence-2026-06.md`: Records
  the `installer-to-disk.sh` ISO-hybrid MBR persistence partition failure and
  the GPT-vs-MBR partitioning split.
- `.agents/docs/notes/lib/podman-compose-staged-file-ownership-2026-04.md`:
  Records per-entry `mode`/`user`/`group`/`scope` plus `dirs.once` behavior for
  staged Podman Compose directories, files, and file secrets.

### Nixbot

- `.agents/docs/notes/nixbot/deploy-system.md`: Canonical `nixbot` deploy,
  bootstrap, SSH, worktree, Terraform, and CI behavior.
- `.agents/docs/notes/nixbot/key-rotation.md`: Canonical deploy-key rotation
  policy and guardrails.

### Reviews

- `.agents/docs/notes/reviews/architecture-review-followups.md`: Condensed
  review findings and the durable refactoring direction after the follow-up
  fixes.

### Secrets

- `.agents/docs/notes/secrets/age-secrets-recipient-eval-2026-06.md`: Records
  the Nix list/function-application parsing bug that put a function into machine
  recipient lists and broke `scripts/age-secrets.sh` JSON evaluation.
- `.agents/docs/notes/secrets/topology-and-operations.md`: Canonical secret
  topology, bootstrap order, and managed secret operations.

### Services

- `.agents/docs/notes/services/edge-and-platform-infra.md`: Canonical
  Cloudflare, GCP, ingress-metadata, import, and sanitization rules.
- `.agents/docs/notes/services/cloudflare-dns-stable-record-keys-2026-04.md`:
  Records the DNS migration from positional Terraform addresses to explicit
  stable record keys, plus remaining positional Cloudflare list inputs.
- `.agents/docs/notes/services/podman-data-dir-ownership-2026-04.md`: Records
  the standard `dirs`/container-scope ownership model for service-local Podman
  data directories plus absolute `dirs` entries for external data roots.
- `.agents/docs/notes/services/postgres-port-publishing.md`: Durable note for
  the `pvl-x2` Postgres Podman Compose host-port publishing failure and
  workaround.
- `.agents/docs/notes/services/openwebui-ollama-host-alias-firewall-2026-04.md`:
  Records the `pvl-a1` versus `pvl-x2` Open WebUI/Ollama difference as a host
  firewall policy issue on published port `11434`, not a compose-network issue.
- `.agents/docs/notes/services/ollama-context-length-128k-2026-04.md`: Records
  the `pvl-a1` decision to set `OLLAMA_CONTEXT_LENGTH=131072` on both Ollama
  service instances so Open WebUI prompts do not get truncated at the prior 4k
  effective context limit.
- `.agents/docs/notes/services/ollama-shared-models-dir-pvl-a1-2026-04.md`:
  Records the `pvl-a1` decision to share one staged Ollama models directory
  across the ROCm and NVIDIA instances while keeping separate per-instance
  Ollama homes.
- `.agents/docs/notes/services/systemd-user-manager.md`: Canonical
  generation-driven `systemd-user-manager` model and dispatcher behavior.
- `.agents/docs/notes/services/home-manager-systemd-user-manager-ordering-2026-04.md`:
  Records the false-positive lingering-user restart on `pvl-x2`, the Home
  Manager versus dispatcher race during dconf activation, and the durable
  identity-stamp plus unit-ordering fix.
- `.agents/docs/notes/services/user-services-platform.md`: Canonical Podman
  compose, nginx, ingress, and soft backend-dependency policy.

### Tooling

- `.agents/docs/notes/tooling/ai-nix-evaluation-source-refs-2026-05.md`: Records
  the AI-agent validation rule to avoid explicit `path:` flake refs and prefer
  `.`, absolute repo paths, or intentional `git+file:///...` refs.
- `.agents/docs/notes/tooling/codex-wrapper-auth-2026-06.md`: Records the local
  `cr`/`cra` Codex wrapper shortcuts for unrestricted mode and numbered
  auth-slot switching.
- `.agents/docs/notes/tooling/data-migrator-host-drain-2026-05.md`: Records the
  generic `data-migrator` port and the gap3-compatible `x.migrator.on` host
  drain semantics.
- `.agents/docs/notes/tooling/bash-completions-2026-06.md`: Records repo-local
  Bash completion sources for operator CLIs and root dev-shell loading.
- `.agents/docs/notes/tooling/migrator-runtime-gate-2026-06.md`: Records the
  runtime-owned `services.migrator` gate, `migratorctl`, managed-unit registry,
  and data-migrator cutover integration.
- `.agents/docs/notes/tooling/nix-run-completion-delegation-2026-06.md`: Records
  the repo-local Bash completion bridge for delegated root-flake `nix run`
  completions.
- `.agents/docs/notes/tooling/gap3-post-87a57ae-port-2026-05.md`: Tracks the
  selective post-`87a57ae` `gap3/master` port, including per-commit port,
  equivalent, and skip decisions.
- `.agents/docs/notes/tooling/gap3-post-8314da5b-port-2026-05.md`: Tracks the
  selective post-`8314da5b` `gap3/master` port plan, per-commit dispositions,
  staged foundations, Cloudflare DNSSEC output support, and skipped
  project-specific work.
- `.agents/docs/notes/tooling/gap3-last50-port-2026-06.md`: Tracks the refreshed
  last-50 `gap3/master` port, shared byte-parity units, local image/manifest
  adaptations, and skipped Abird/GAP3 host-specific commits.
- `.agents/docs/notes/tooling/gap3-unit4-stack-registry-foundation-2026-05.md`:
  Records the Unit 4 stack/service-registry/package helper foundation port and
  the Abird-specific, secret-policy, nginx-composer, and mail-directory
  deferrals.
- `.agents/docs/notes/tooling/gap3-unit5-stack-secrets-2026-05.md`: Records the
  Unit 5 stack-aware secret helper port, the local `pvl` recipient-policy split,
  and the skipped Abird/Gap3 and absent Kanidm/Stalwart service-library work.
- `.agents/docs/notes/tooling/gap3-unit6-nginx-composer-2026-05.md`: Records the
  Unit 6 nginx ingress composer, redirect vhost, proxy buffering, stack unit,
  and Podman Compose trusted-CA helper port, plus skipped Abird/GAP3 route
  applications.
- `.agents/docs/notes/tooling/puppeteer-chrome-nix-ld-2026-04.md`: Records the
  `nix-ld` runtime-library fix for local Puppeteer Chrome binaries on NixOS.
- `.agents/docs/notes/tooling/pvl-tmux-extended-keys-2026-06.md`: Records the
  `pvl` Home Manager tmux extended-key settings needed for Codex `Shift+Enter`
  newline handling inside tmux.
- `.agents/docs/notes/tooling/pvl-terminal-shift-enter-2026-06.md`: Records the
  terminal-side `Shift+Enter` CSI-u mappings for Alacritty, foot, and VS Code,
  plus the Ghostty config-open MIME default fix.
- `.agents/docs/notes/tooling/pvl-vscode-direnv-devshells-2026-04.md`: Records
  the move from `arrterian.nix-env-selector` to `mkhl.direnv` plus the root
  flake `devShells.default`/`devShells.full` abstraction in
  `lib/flake/dev-shells.nix`.
- `.agents/docs/notes/tooling/repo-tooling.md`: Canonical Bash entrypoint,
  lint/fmt, package-local verification, and docs-maintenance rules.

## Playbooks

- `.agents/docs/playbooks/ai-docs-reconsolidation.md`: Periodic process for
  merging overlapping docs back into a smaller canonical set.
- `.agents/docs/playbooks/cloudflare-apps.md`: Reusable Cloudflare apps
  workflow.
- `.agents/docs/playbooks/cloudflare-email-routing.md`: Reusable Cloudflare
  email routing workflow.
- `.agents/docs/playbooks/cloudflare-state-adoption.md`: Reusable Cloudflare
  import and adoption workflow.
- `.agents/docs/playbooks/gcp-ad-hoc-nixos-bootstrap.md`: Procedure for creating
  ad hoc GCP bootstrap VMs and converting them to NixOS with repo or generic
  host configs.
- `.agents/docs/playbooks/nixbot-deploy.md`: Reusable nixbot deploy workflow.
- `.agents/docs/playbooks/nixbot-key-rotation-execution.md`: Phased nixbot key
  rotation execution procedure.
- `.agents/docs/playbooks/nixbot-key-rotation-keygen.md`: Nixbot key generation
  and prep procedure.

## Runs

- `.agents/runs/`: Temporary staging area for active multi-step or multi-agent
  work. Keep it empty when there is no active staged run.

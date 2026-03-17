# Repo Summary (2026-03)

## Purpose

Personal NixOS and Home Manager configuration managed as a Nix flake. The repo
also owns Cloudflare infrastructure via OpenTofu, repo-local runnable packages,
and the `nixbot` automated deployment system.

## Managed hosts

| Host | Role |
|---|---|
| `pvl-a1` | Primary desktop/laptop (AMD iGPU + NVIDIA dGPU, x86_64-linux) |
| `pvl-x2` | Secondary desktop, x86_64-linux |
| `llmug-rivendell` | Bastion + service host (runs `nixbot`, Podman compose stacks), x86_64-linux |

All three are declared in `hosts/default.nix` using `nixpkgs.lib.nixosSystem` and
share `commonModules` (home-manager, agenix, overlays).

Host-specific deploy metadata (bootstrap user, SSH keys, dependency ordering, age
identity key paths) is in `hosts/nixbot.nix`.

## Flake structure

- `flake.nix` — inputs, `nixosConfigurations`, `nixosImages`, `pkgs.*`, overlays,
  and per-system formatter.
- Flake inputs: `nixpkgs` (25.11), `unstable`, `home-manager` (25.11), `agenix`,
  `nixos-hardware`, `vscode-ext`, `llm-agents`, `antigravity`, `codex`,
  `p7-borders`, `p7-cmds`, `noctalia`.
- `pkgs.<system>.*` — custom top-level output for repo-local packages (not
  `packages`). Examples: `pkgs.x86_64-linux.hello-rust`,
  `pkgs.x86_64-linux.cloudflare-workers.llmug-hello.deploy`.
- `overlays.default` — composed overlay applied to all hosts.

## Module library (`lib/`)

Single-topic NixOS modules imported by host definitions:

- `audio`, `boot`, `desktop-base`, `flatpak`, `gdm`, `gdm-rdp`, `gnome`, `gpg`
- `hardware`, `incus`, `incus-machine`, `kernel`, `keyd`, `locale`, `mdns`
- `neovim`, `network`, `network-wifi`, `nix`, `nix-ld`, `nixbot/*`
- `openssh`, `options`, `podman`, `printing`, `profiles/*`, `seatd`, `security`
- `sudo`, `swap-auto`, `sway`, `sysctl-*`, `systemd`, `systemd-user-manager`
- `users`, `virtualization`

Key notable modules:
- `lib/nixbot/default.nix` — installs `nixbot` deploy user and public keys on all
  nodes.
- `lib/nixbot/bastion.nix` — installs forced-command ingress key on the bastion.
- `lib/systemd-user-manager.nix` — bridges Podman user units into
  `nixos-rebuild switch` lifecycle.
- `lib/incus-machine.nix` — reusable Incus guest template.

## Deployment system (`nixbot`)

Primary entrypoint: `scripts/nixbot-deploy.sh`.

Flow:
1. CI (`.github/workflows/nixbot.yaml`) triggers via `--bastion-trigger` over SSH
   to the bastion host.
2. Bastion runs `nixos-rebuild` build/switch against each managed host.
3. Cloudflare OpenTofu runs are integrated as `tf-dns`, `tf-platform`,
   `tf-apps` phases (automatically before/after host deploy when using
   `--action all`).

Deploy modes (via `--action`):
- `all` — TF-dns, TF-platform, host build+deploy, TF-apps (default).
- `build` / `deploy` / `tf` / `tf-dns` / `tf-platform` / `tf-apps`
- `--dry` is a flag that applies to any action (plan-only for TF, dry-run for
  NixOS).

Parallelism:
- Build: `DEPLOY_BUILD_JOBS` / `--build-jobs`
- Deploy: `DEPLOY_JOBS` / `--deploy-jobs`
- Deploy is wave-based on `deps` declared in `hosts/nixbot.nix`.
- `--bastion-first` forces bastion to wave 1.

CI uses Tailscale OAuth/OIDC (`tailscale/github-action@v4`, `permissions.id-token:
write`).

See `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md` for full details.

## Secrets (`agenix`)

- Recipients are declared in `data/secrets/default.nix`.
- Encrypted files use `.key.age` suffix throughout.
- `scripts/age-secrets.sh` manages encrypt/decrypt/clean operations.

Key namespaces under `data/secrets/`:
- `machine/<host>.key.age` — per-host age identity injected before activation.
- `nixbot/nixbot.key.age` — shared downstream SSH deploy key (bastion → hosts).
- `bastion/nixbot-bastion-ssh.key.age` — forced-command ingress key (CI → bastion).
- `tailscale/<host>.key.age` — Tailscale auth keys for Incus guests.
- `services/<service>/*.key.age` — bastion-host service secrets.
- `tf/cloudflare/**/*.tfvars.age` / `cloudflare/*.key.age` — Cloudflare TF
  credentials and sensitive tfvars.
- `data/secrets/tf/**` — other TF sensitive inputs.

Trust domains:
- Deploy SSH key and machine age identity are intentionally separate.
- Machine age identity is injected at `/var/lib/nixbot/.age/identity` before each
  activation; `agenix` uses it for service-secret decrypt at activation time.

See `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md`.

## Services (bastion host)

Bastion-host user services are managed as Podman compose stacks under
`services.podmanCompose` (module in `lib/`), run by the `pvl` user.

Active stacks: `beszel`, `dockge`, `docmost`, `immich`, `shadowsocks`.  
Compose trees live under `hosts/<bastion-host>/compose/`.

Secrets injected via `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret`.

`lib/systemd-user-manager.nix` bridges user units into `nixos-rebuild` lifecycle
so changed units restart cleanly.

See `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md` and
`docs/ai/notes/services/bastion-service-migration-consolidated-2026-03.md`.

## Cloudflare (OpenTofu)

Three runnable phase projects, shared module under `tf/modules/cloudflare/`:

| Project | Phase | Contents |
|---|---|---|
| `tf/cloudflare-dns/` | pre-deploy | DNS records |
| `tf/cloudflare-platform/` | pre-deploy | Zero Trust Access, R2, DNSSEC, zone settings, Email Routing, cert packs |
| `tf/cloudflare-apps/` | post-deploy | Workers services, versions, deployments, routes, custom domains |

Sensitive inputs encrypted under `data/secrets/tf/cloudflare/` and decrypted at
run time by `scripts/nixbot-deploy.sh`.  
Public inputs in `*.auto.tfvars` inside each project directory.

State adoption status as of 2026-03-16:
- `tf-platform` — fully adopted, no-op.
- `tf-apps` (`llmug-hello`) — imported; `--dry` not yet no-op due to immutable
  version/deployment metadata divergence from old wrangler artifact.
- `tf-dns` — previously adopted; not re-imported in the March 2026 pass.

Workers source lives in `pkgs/cloudflare-workers/<worker>/` and is deployed
through the Nix/OpenTofu flow.

See `docs/ai/notes/services/cloudflare-opentofu-consolidated-2026-03.md` and
`docs/ai/notes/services/cloudflare-adoption-and-workers-consolidated-2026-03.md`.

## Repo-local packages (`pkgs/`)

- `pkgs/hello-rust/` — simple Rust demo package.
- `pkgs/cloudflare-workers/llmug-hello/` — Cloudflare Worker deployed via
  OpenTofu, source adopted from live export.
- `pkgs/ext/` — standalone derivations consumed by overlays and helper scripts.
- Aggregated into the root flake's custom `pkgs.<system>.*` output via
  `pkgs/default.nix` collector.

## Desktop host notes (`pvl-a1`)

- AMD iGPU + NVIDIA dGPU with `supergfxd`, `s2idle` only.
- Suspend hang was the primary tracked issue (watchdog reboot); triage order is
  watchdog → kernel variant → NVIDIA stack details.
- GNOME autolock failures traced to Caffeine extension idle inhibitor.
- `amdxdna` probe failures are likely benign firmware/driver mismatch unrelated
  to display; safe to blacklist if NPU is unused.

See `docs/ai/notes/hosts/desktop-investigations-consolidated-2026-03.md`.

## Incus / VM hosts

- Incus guests share a canonical template and secret model via
  `lib/incus-machine.nix`.
- Tailscale auth keys stored per guest in `data/secrets/tailscale/<host>.key.age`.
- AMD GPU passthrough documented for an Ollama guest.

See `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md` and
`docs/ai/notes/hosts/incus-guest-ollama-amd-gpu-2026-03.md`.

## Open work (TODO.md)

- `nixbot-deploy` parallel `--dry` support (blocked on eval isolation in a
  fresh clone dir).
- GH workflow: allow dry runs on PRs without compromising review security.
- Separate staging keys with read-only TF state and platform access.
- Multiple env keys support with Nix-based auto-selection.

## Key doc map

| Topic | File |
|---|---|
| Deployment architecture | `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md` |
| Key rotation model | `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md` |
| Secret topology | `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md` |
| age-secrets `--clean` | `docs/ai/notes/secrets/age-secrets-clean-flag-2026-03.md` |
| Podman compose platform | `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md` |
| Bastion services migration | `docs/ai/notes/services/bastion-service-migration-consolidated-2026-03.md` |
| Cloudflare OpenTofu layout | `docs/ai/notes/services/cloudflare-opentofu-consolidated-2026-03.md` |
| Cloudflare adoption status | `docs/ai/notes/services/cloudflare-adoption-and-workers-consolidated-2026-03.md` |
| OpenSSH centralization | `docs/ai/notes/services/openssh-module-centralization-2026-03.md` |
| Cloudflare tunnel hosts | `docs/ai/notes/hosts/cloudflare-tunnel-hosts-2026-03.md` |
| Desktop investigations | `docs/ai/notes/hosts/desktop-investigations-consolidated-2026-03.md` |
| Incus VM template | `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md` |
| Incus Ollama AMD GPU | `docs/ai/notes/hosts/incus-guest-ollama-amd-gpu-2026-03.md` |
| Flake pkgs export | `docs/ai/notes/apps/root-flake-app-exports-and-git-source-2026-03.md` |
| Flake collectors | `docs/ai/notes/apps/auto-discovered-flake-collectors-2026-03.md` |
| Deployment fixes | `docs/ai/notes/deployment/deployment-fixes-consolidated-2026-03.md` |
| Sensitive doc cleanup | `docs/ai/notes/services/docs-sensitive-info-cleanup-2026-03.md` |
| Public DNS test record | `docs/ai/notes/services/public-dns-test-a-record-2026-03.md` |

# Codebase Overview

_Session: 2026-03_

This note provides a high-level map of the repository for agents that need
orientation before diving into a specific area.

---

## Purpose

A personal **NixOS + Home Manager** configuration repository, managed as a Nix
flake.  It covers:

- Declarative system definitions for three hosts.
- Modular single-topic NixOS modules.
- Custom local packages (Rust, Cloudflare Workers).
- Automated build/deploy orchestration via a bastion host.
- Cloudflare DNS/platform/worker infrastructure managed with OpenTofu.
- Home Manager user environment.
- Age-encrypted secrets (agenix).
- AI-agent documentation under `docs/ai/`.

---

## Top-Level Layout

```
flake.nix          # Flake inputs and system outputs
flake.lock         # Pinned inputs
README.md          # Human-facing overview
AGENTS.md          # AI agent conventions
TODO.md            # Planned improvements
treefmt.toml       # Formatter config

hosts/             # Per-host NixOS definitions + deploy mapping
lib/               # Single-topic NixOS modules (~45 files)
overlays/          # nixpkgs overlays
pkgs/              # Repo-local packages (own flakes, auto-aggregated)
users/             # Home Manager user modules
data/              # Age-encrypted secrets + wallpapers
scripts/           # Build/deploy automation
tf/                # OpenTofu (Cloudflare) projects
docs/              # Documentation (human + AI)
.github/workflows/ # GitHub Actions
```

---

## Hosts

Defined under `hosts/` and composed in `flake.nix`.

| Host | Role | System | Notes |
|------|------|--------|-------|
| **pvl-a1** | Desktop workstation | x86_64-linux | ASUS FA401WV, LUKS btrfs, GNOME/Sway |
| **pvl-x2** | Bastion / mini-server | x86_64-linux | GMTEK EVO-X2, acts as SSH gate for CI deploys, Incus host |
| **llmug-rivendell** | Incus guest / services | x86_64-linux | systemd-container profile, deployed via pvl-x2, depends on pvl-x2 |

Deploy mapping and per-host `deps` (dependency ordering) live in
`hosts/nixbot.nix`.

---

## Modules (`lib/`)

Single-topic modules imported directly by hosts.  Key groupings:

- **System**: `nix.nix`, `boot.nix`, `kernel.nix`, `network.nix`,
  `security.nix`, `openssh.nix`, `systemd.nix`, `locale.nix`
- **Containers / Virt**: `podman.nix` (the large platform module),
  `incus.nix`, `incus-machine.nix`, `virtualization.nix`
- **Desktop**: `gnome.nix`, `gdm.nix`, `gdm-rdp.nix`, `sway.nix`,
  `desktop-base.nix`, `flatpak.nix`, `audio.nix`
- **Kernel tuning**: `sysctl-inotify.nix`, `sysctl-coredump.nix`,
  `sysctl-panic.nix`, `sysctl-sysrq.nix`, `sysctl-vm.nix`
- **Devices**: `devices/asus-fa401wv.nix`, `devices/gmtek-evo-x2.nix`
- **Hardware**: `hardware/nvidia.nix`, `hardware/amdgpu-strix.nix`,
  `hardware/mesa.nix`, `hardware/mt7921e.nix`, `hardware/logitech.nix`,
  `hardware/openrgb.nix`, `hardware/tpm.nix`
- **Nixbot**: `lib/nixbot/default.nix` (user/key setup),
  `lib/nixbot/bastion.nix` (forced-command SSH gate)
- **Profiles**: `profiles/all.nix`, `profiles/core.nix`,
  `profiles/desktop-*.nix`, `profiles/systemd-container.nix`
- **Utilities**: `flakelib.nix` (auto-discovery), `options.nix`,
  `users.nix`, `swap-auto.nix`

---

## Custom Packages (`pkgs/`)

Each subdirectory owns its own `flake.nix` and is auto-aggregated by
`lib/flakelib.nix` into a top-level `pkgs.<system>.*` flake output (not the
standard `packages` attr).

| Package | Language | Notes |
|---------|----------|-------|
| `hello-rust` | Rust | Minimal example |
| `cloudflare-workers/llmug-hello` | TypeScript/JS | Example Cloudflare Worker |
| `cloudflare-workers/openseal` | TypeScript/JS | Cloudflare Worker app |
| `cloudflare-workers/priyasuyash` | TypeScript/JS | Cloudflare Worker app |

`pkgs/ext/` holds standalone derivations (`handbrake.nix`, `nvidia-driver.nix`,
`zed.nix`, `p7-borders.nix`, `p7-cmds.nix`) consumed by overlays and helper
scripts rather than by the flake export tree.

Usage example:
```bash
nix build .#pkgs.x86_64-linux.hello-rust
nix run .#pkgs.x86_64-linux.cloudflare-workers.llmug-hello.deploy -- --dry
```

---

## Users (`users/`)

Home Manager modules for user `pvl`.  Modules include: `bash`, `tmux`,
`neovim`, `vscode`, `git`, `firefox`, `sway`, `zoxide`, `fzf`, `ranger`,
`gtk`, `gnome`, `dotfiles`, `inputrc`, `xdg-user-dirs`.

---

## Overlays (`overlays/`)

| File | Purpose |
|------|---------|
| `default.nix` | Composes all overlays |
| `pkgs.nix` | Injects custom derivations from `pkgs/ext/` |
| `unstable.nix` | Selectively enables unstable channel packages |
| `unstable-sys.nix` | System-level unstable overrides |
| `pvl.nix` | User-specific customizations |

---

## Secrets (`data/secrets/`)

Age-encrypted with `agenix`.  Never read `.key` files directly.

```
data/secrets/
├── default.nix          # Agenix recipient map
├── machine/             # Per-host identity keys (pvl-a1, pvl-x2, llmug-rivendell)
├── nixbot/              # Deploy user keys
└── cloudflare/          # OpenTofu credentials
```

See `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md`
for the trust model and bootstrap order.

---

## Automation Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `nixbot-deploy.sh` | Primary orchestrator (~3,500 lines): multi-phase deploy, parallel build/deploy waves, dependency ordering, bastion-trigger mode |
| `age-secrets.sh` | Encrypt/decrypt/rotate age files |
| `update-nvidia.sh` | NVIDIA driver update helper |
| `update-gnome-ext.sh` | GNOME extension metadata refresh |
| `update-fetchzip-in-derv-hashes.sh` | Derivation hash updater |
| `git-install-hooks.sh` | Git hook installer |
| `cloudflare-export.py` | Cloudflare state export/analysis |

`nixbot-deploy.sh` re-execs itself inside a `nix shell` to guarantee a
consistent toolchain (age, git, jq, nixos-rebuild, openssh, opentofu) pinned
by the repo's flake inputs.

---

## OpenTofu / Terraform (`tf/`)

Three deployment phases; each has its own project directory:

| Phase | Directory | When |
|-------|-----------|------|
| 1 – DNS | `tf/cloudflare-dns/` | Before host deploy |
| 2 – Platform | `tf/cloudflare-platform/` | Before host deploy |
| 3 – Apps | `tf/cloudflare-apps/` | After host deploy |

Shared module: `tf/modules/cloudflare/`.

Run via:
```bash
scripts/nixbot-deploy.sh --action tf-dns        # phase 1 only
scripts/nixbot-deploy.sh --action tf-platform   # phase 2 only
scripts/nixbot-deploy.sh --action tf-apps       # phase 3 only
scripts/nixbot-deploy.sh --action tf            # phases 1-3
scripts/nixbot-deploy.sh --action all           # phases + host deploy
```

See `docs/ai/notes/services/cloudflare-opentofu-consolidated-2026-03.md` for
layout rules and source-of-truth guidance.

---

## Deployment Architecture

```
GitHub Actions (.github/workflows/nixbot.yaml)
        │
        │ SSH with restricted forced-command key
        ▼
  pvl-x2 (bastion)
        │ runs /var/lib/nixbot/nixbot-deploy.sh
        ▼
  Phase 1: tf-dns  (OpenTofu)
  Phase 2: tf-platform  (OpenTofu)
  Phase 3: NixOS build + deploy (parallel, dependency-ordered waves)
  Phase 4: tf-apps  (OpenTofu)
```

- CI workflow is intentionally thin: no script is uploaded at runtime.
- Bastion's forced-command key is pre-registered to one allowed path.
- Dependency waves: `llmug-rivendell` waits for `pvl-x2` to finish.
- `DEPLOY_BUILD_JOBS` / `DEPLOY_JOBS` control parallelism.
- `DEPLOY_BASTION_FIRST` prioritizes the bastion in build/deploy ordering.

Detailed architecture: `docs/deployment.md`  
Canonical orchestration notes: `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md`

---

## Flake Inputs (key)

Defined in `flake.nix`:

| Input | Purpose |
|-------|---------|
| `nixpkgs` (25.11 stable) | Primary package set |
| `nixpkgs-unstable` | Unstable channel (via overlays) |
| `home-manager` | User environment management |
| `agenix` | Age-based secret management |
| `nixos-hardware` | Hardware-specific profiles |
| `vscode-extensions` | Pinned VS Code extension set |
| LLM/agent inputs | Upstream agent tooling |
| Cloudflare extension | CF-specific Nix modules |

---

## Cross-Reference: Key Docs

| Topic | File |
|-------|------|
| Deployment architecture | `docs/deployment.md` |
| Incus VM setup | `docs/incus-vms.md` |
| OpenTofu layout | `tf/README.md` |
| Package layout | `pkgs/README.md` |
| Nixbot deploy notes | `docs/ai/notes/nixbot/deploy-system-consolidated-2026-03.md` |
| Key rotation | `docs/ai/notes/nixbot/key-rotation-and-playbooks-consolidated-2026-03.md` |
| Secrets topology | `docs/ai/notes/secrets/secrets-infra-bootstrap-and-topology-2026-03.md` |
| Cloudflare OpenTofu | `docs/ai/notes/services/cloudflare-opentofu-consolidated-2026-03.md` |
| Podman platform | `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md` |
| AI docs index | `docs/ai/README.md` |

# Abird Last-30 Port Audit (2026-06)

## Scope

Reviewed the last 30 commits on `abird/master` as of 2026-06-12 and ported the
remaining relevant shared implementation into
`worktrees/abird-last30-port-20260612`.

Secret-bearing commits were inspected through Git metadata and path names only.
No `data/secrets/**/*.key` contents were read.

The session started from local `master` at
`ad2456f9 fix(nixbot): use system deploy command` and source `abird/master` at
`c6da9ded fix(nixbot): use system deploy command`.

## Commit Ledger

| Commit     | Subject                                              | Result                                                                                                                                                      |
| ---------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20ff43a1` | `fix(pkg): gate wrangler deploy to linux`            | Already ported byte-for-byte in `pkgs/cloudflare-apps/llmug-hello/default.nix`.                                                                             |
| `98f1a3f2` | `feat: enable zulip-robin on abird-corp (#5)`        | Skipped. Abird host/service/secret wiring; package dependency chain was outside this last-30 port unit.                                                     |
| `db9d610f` | `feat(hosts): abird-labs (formerly tic-tac-toe)`     | Skipped. Abird host, secret, stack, and data-migrator profile inventory.                                                                                    |
| `0827ffe9` | `chore(gitignore): track secret dirs`                | Skipped as intentional local divergence. This repo keeps `.crt` tracking and `.kilo/` ignore behavior.                                                      |
| `0b32a9f6` | `fix(incus): resolve instance selectors`             | Already ported byte-for-byte in `lib/incus/helper.sh`.                                                                                                      |
| `b3238cee` | `fix(nixbot): harden parent readiness`               | Already ported in local `nixbot`; current pass kept the behavior while syncing later deploy-host work.                                                      |
| `28ae0c4a` | `fix(abird): grant labs service secrets`             | Skipped. Abird secret-recipient and host inventory only.                                                                                                    |
| `3b94b663` | `refactor(nginx): add path route names`              | Already ported byte-for-byte in `lib/services/nginx/default.nix`.                                                                                           |
| `adf0f248` | `fix(nginx): honor Cloudflare scheme`                | Already ported byte-for-byte in `lib/services/nginx/compose/nginx.conf`.                                                                                    |
| `ceb01187` | `fix(abird): scope Zulip upload routes`              | Skipped. Abird host ingress/docs only.                                                                                                                      |
| `66b14818` | `Use staged dirty deploys in data migrator`          | Already ported byte-for-byte in `pkgs/tools/data-migrator/data-migrator.py` and tests.                                                                      |
| `85573678` | `feat(nixbot): add config overrides`                 | Already ported/adapted in local `nixbot`; current pass retains local docs shape.                                                                            |
| `810f31a4` | `style(docs): wrap nixbot override notes`            | Already adopted through local documentation shape.                                                                                                          |
| `0d92028c` | `feat(nixbot): improve override summary`             | Already ported/adapted in local `nixbot`.                                                                                                                   |
| `f692d006` | `chore(flake): update root, vscode`                  | Skipped. Root lock graphs differ; VS Code package content already matched.                                                                                  |
| `8e91401e` | `feat(installer): add live persistence`              | Already ported byte-for-byte for shared installer scripts/modules except local installer target config.                                                     |
| `86b7e4af` | `fix(nixbot): omit skipped hosts`                    | Already ported/adapted in local `nixbot`.                                                                                                                   |
| `e0e08d1c` | `refactor(hosts): simplify Abird packages`           | Skipped. Abird host package lists only.                                                                                                                     |
| `5f24e136` | `fix(installer): support MBR persistence`            | Already ported byte-for-byte in `lib/installer/installer-to-disk.sh`.                                                                                       |
| `fc67387c` | `fix(nixbot): require tfvars for writes`             | Skipped for Terraform discovery. Local repo intentionally keeps broader provider/project `*.tfvars.age` discovery rather than Abird's `secrets.tfvars.age`. |
| `4478f33d` | `fix(nixbot): repo secrets resolution`               | Already ported byte-for-byte except local documentation shape.                                                                                              |
| `e7e94aec` | `feat(incus): add project route reconciler`          | Already ported byte-for-byte in `lib/incus/default.nix` and `lib/incus/helper.sh`.                                                                          |
| `a605937c` | `docs(agents): require docs closeout`                | Already adopted locally as `e2584e2f`; no extra change.                                                                                                     |
| `f80043f3` | `feat(search): add search service package (#6)`      | Skipped per user correction. Do not import `srv-search` in this repo during this port pass.                                                                 |
| `9b85de10` | `feat(nixbot): add deploy-host, refine ssh pathways` | Ported the shared `nixbot` remote build/deploy-host logic and Bash completion updates, preserving local tfvars discovery.                                   |
| `57c4803f` | `feat(nixbot): complete remote activation`           | Ported the shared `remote-activate` request flow and deploy-host activation path, preserving local tfvars discovery.                                        |
| `e01f7df7` | `fix(tailscale): use client routing`                 | Already ported byte-for-byte in `lib/incus-vm.nix` and `lib/network.nix`.                                                                                   |
| `8e6e2e25` | `docs(nixbot): record pvl-x2 deploy gaps`            | Skipped. Abird/pvl-x2 operational note from the source repo.                                                                                                |
| `020b4883` | `style(docs): format nixbot note`                    | Skipped with the source-only note.                                                                                                                          |
| `c6da9ded` | `fix(nixbot): use system deploy command`             | Already ported byte-for-byte in `lib/nixbot/ci.nix`; `pkgs/tools/nixbot/nixbot.sh` remains byte-identical except the preserved local tfvars block.          |

## Parity Audit

Byte-for-byte parity with `abird/master` after the port:

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `lib/services/nginx/default.nix`
- `lib/services/nginx/compose/nginx.conf`
- `lib/nixbot/ci.nix`
- `lib/incus-vm.nix`
- `lib/network.nix`
- `pkgs/tools/data-migrator/data-migrator.py`
- `pkgs/tools/data-migrator/test_data_migrator.py`
- `lib/installer/installer-to-disk.sh`
- `lib/installer/default.nix`
- `lib/installer/builder.sh`
- `lib/installer/build-image.nix`
- `lib/installer/module.nix`
- `lib/installer/offline-install.sh`
- `lib/installer/persistence.nix`
- `lib/installer/persistence.sh`
- `pkgs/cloudflare-apps/llmug-hello/default.nix`

Intentional remaining divergences:

- `pkgs/tools/nixbot/nixbot.sh`: only the Terraform secret discovery block
  differs from Abird; this repo keeps recursive provider/project `*.tfvars.age`
  discovery.
- `lib/installer/config/default.nix`: local physical workstation installer
  target config is repo-specific.
- `.gitignore`: local `.crt` secret tracking and `.kilo/` ignore behavior are
  repo-specific.
- `pkgs/tools/data-migrator/profiles.nix`: Abird labs/OpenClaw profile entries
  are host/service inventory and were skipped.
- `pkgs/srv/search/**`: skipped per user correction.

## Validation

- `bash -n pkgs/tools/nixbot/nixbot.sh pkgs/tools/nixbot/nixbot.bash`
- `shellcheck pkgs/tools/nixbot/nixbot.sh`
- `nix run .#nixbot -- --help`

# Abird Last-15 Port Audit (2026-06)

## Scope

Reviewed the last 15 commits on `abird/master` as of 2026-06-12 and ported
shared implementation changes into the `codex/abird-port-20260612` worktree.

Secret-bearing commits were inspected through git metadata and path names only;
no `data/secrets/**/*.key` contents were read.

## Commit Ledger

| Commit | Subject | Result |
| --- | --- | --- |
| `db9d610f` | `feat(hosts): abird-labs (formerly tic-tac-toe)` | Skipped. Host, secret, stack-inventory, and Abird data-migrator profile changes are Abird-specific. |
| `0827ffe9` | `chore(gitignore): track secret dirs` | Already present locally for secret directory tracking. Kept local `.crt` and `.kilo/` ignore differences. |
| `0b32a9f6` | `fix(incus): resolve instance selectors` | Ported byte-for-byte in `lib/incus/helper.sh`. |
| `b3238cee` | `fix(nixbot): harden parent readiness` | Ported relevant `pkgs/tools/nixbot/nixbot.sh` changes: `resourceId` parent resource lookup and stale primary ControlMaster clearing on retry. |
| `28ae0c4a` | `fix(abird): grant labs service secrets` | Skipped. Abird secret-recipient and host inventory only. |
| `3b94b663` | `refactor(nginx): add path route names` | Ported byte-for-byte in `lib/services/nginx/default.nix`. |
| `adf0f248` | `fix(nginx): honor Cloudflare scheme` | Ported byte-for-byte in `lib/services/nginx/compose/nginx.conf`. |
| `ceb01187` | `fix(abird): scope Zulip upload routes` | Skipped. Abird host ingress/docs only, no shared lib/pkg changes. |
| `66b14818` | `Use staged dirty deploys in data migrator` | Ported byte-for-byte in `pkgs/tools/data-migrator/data-migrator.py` and tests. |
| `85573678` | `feat(nixbot): add config overrides` | Ported code, completion, `.gitignore`, and deployment docs. Adapted agent note into this repo's current `deploy-system.md` note. |
| `810f31a4` | `style(docs): wrap nixbot override notes` | Adopted through local documentation shape; no separate content change needed beyond wrapped docs. |
| `0d92028c` | `feat(nixbot): improve override summary` | Ported manually on top of existing skipped-host banner logic: target annotations plus config override line. |
| `f692d006` | `chore(flake): update root, vscode` | VS Code package content already matched Abird. Root lock intentionally left local because the lock graphs differ. |
| `8e91401e` | `feat(installer): add live persistence` | Mostly already present locally. Ported missing non-LUKS/optional-ID support from `module.nix` and `offline-install.sh`; kept local installer target config and MBR persistence fix. |
| `86b7e4af` | `fix(nixbot): omit skipped hosts` | Already partly present locally. Kept existing snapshot/deploy skip handling and ported the remaining banner/summary pieces through the `0d92028c` merge. |

## Parity Audit

Byte-for-byte parity with `abird/master` after the port:

- `lib/incus/helper.sh`
- `lib/services/nginx/default.nix`
- `lib/services/nginx/compose/nginx.conf`
- `lib/installer/module.nix`
- `lib/installer/offline-install.sh`
- `lib/ext/vscode/default.nix`
- `pkgs/tools/data-migrator/data-migrator.py`
- `pkgs/tools/data-migrator/test_data_migrator.py`
- `pkgs/tools/nixbot/nixbot.bash`

Intentional remaining divergences:

- `lib/installer/config/default.nix`: local physical `pvl-*` live-installer
  targets and GNOME/persistence defaults are repo-specific.
- `lib/installer/installer-to-disk.sh`: local MBR persistence partition support
  is newer than Abird's GPT-only version.
- `pkgs/tools/nixbot/nixbot.sh`: remaining diff is older Terraform secret path
  policy divergence, not part of Abird's last 15 commits.
- `flake.lock`: root lock graph differs between repos; only VS Code package
  content was relevant and already matched.
- `pkgs/tools/data-migrator/profiles.nix`: Abird labs inventory was skipped as
  host-specific configuration.

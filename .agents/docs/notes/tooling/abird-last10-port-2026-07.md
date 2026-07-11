# Abird Last-10 Port 2026-07

Reviewed the newest 10 commits on `abird/master` at `4b6d3859` from local base
`2c6eeff1`.

## Logical Units

- Native compose parity already present locally: `0ac1dc8f`, `2c619399`,
  `366b1c69`, and `27e89088` were represented by local commits `952ce11c`,
  `695fe5d3`, `7ecd4e9a`, and `2c6eeff1`.
- Migration-manager native user-unit drain: `cc18493f` was adopted for shared
  `lib/`, `pkgs/tool/migration-manager`, data-migrator integration, and
  completion wiring.
- Migration-manager docs adaptation: `b2d56752` was adopted into local docs
  surfaces without copying Abird's consolidated docs layout.
- Nixbot global lock and signal handling: `e8d158ea` and `4b6d3859` were adopted
  for shared nixbot code and tests, excluding Abird-only consolidated docs.
- Stalwart recovery trap clarification: `1f968108` was already represented
  locally with byte parity.

## Commit Ledger

| Commit     | Subject                                           | Disposition                                                                                                                                   |
| ---------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `4b6d3859` | `fix(nixbot): preserve activation signals`        | Ported cleanly in `pkgs/tools/nixbot/{nixbot.sh,tests/test_nixbot.py}`.                                                                       |
| `27e89088` | `fix(podman-compose): keep pull sidecars`         | Already adopted locally as `2c6eeff1`; local docs remain PVL-specific.                                                                        |
| `e8d158ea` | `feat(nixbot): add global lock override`          | Ported code in `pkgs/tools/nixbot/{nixbot.bash,nixbot.sh,tests/test_nixbot.py}`; skipped Abird consolidated docs.                             |
| `b2d56752` | `docs: update migration-manager graph docs`       | Adopted as local docs updates for migration-manager, podman-compose, completion notes, and this ledger; did not copy Abird's full docs index. |
| `cc18493f` | `feat(migration-manager): manage user units`      | Adopted shared migration-manager native user-service/target drain support, package rename, data-migrator command rename, and tests.           |
| `366b1c69` | `fix(podman-compose): migrate state before adopt` | Already adopted locally as `7ecd4e9a`; code/test parity already present.                                                                      |
| `66b5046f` | `docs: record native compose migration`           | Skipped direct port; local equivalent is `41f11316` and local notes.                                                                          |
| `2c619399` | `fix(nixbot): support native compose deploys`     | Already adopted locally as `695fe5d3`; later nixbot files were refreshed by this port.                                                        |
| `0ac1dc8f` | `feat(podman-compose): use native user graph`     | Already adopted locally as `952ce11c` with local adaptations; later migration-manager registration was adopted through `cc18493f`.            |
| `1f968108` | `fix(stalwart): clarify recovery trap`            | Already equivalent locally; `lib/services/stalwart/helper.sh` remained byte-identical.                                                        |

## Byte-Parity Targets

The shared code parity set for this port is:

- `lib/flake/service-module.nix`
- `lib/flake/tests/default.nix`
- `lib/podman-compose/default.nix`
- `lib/services/migration-manager/default.nix`
- `lib/services/migration-manager/options.nix`
- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `lib/systemd-user-manager/tests/module.nix`
- `lib/systemd-user-manager/tests/test_helper.py`
- `pkgs/support/bash-completions/nix-run-apps.bash`
- `pkgs/tool/migration-manager/**`
- `pkgs/tools/data-migrator/{data-migrator.py,default.nix,tests/test_data_migrator.py}`
- `pkgs/tools/nixbot/{nixbot.bash,nixbot.sh,tests/test_nixbot.py}`

## Intentional Divergences

- `lib/flake/root.nix` keeps this repo's PVL-specific flake inputs,
  `machineProfile ? null`, and global `../systemd-user-manager` import.
- `pkgs/tools/data-migrator/profiles.nix` keeps the existing profile inventory;
  Abird OpenClaw and labs profile rows are Abird topology data.
- `docs/*` and `.agents/docs/*` are adapted to this repo's local docs structure
  rather than copied byte-for-byte from Abird.
- `pkgs/tools/nixbot/tests/default.nix` adds `pkgs.util-linux` so the new
  `flock`-based host-local lock test works inside the Nix sandbox.
- Abird host files, consolidated Abird docs, plans, and support scripts such as
  `scripts/support/abird-gondor-to-nest-migrate.sh` were not ported.

# Abird Latest Post-928a Port 2026-07

Reviewed the newest seven commits on `abird/master` after `928a0a72`, ending at
`446992e9`, from local base `eed5cbf5`.

## Logical Units

- Rust Tic-Tac-Toe lab package: `b0d00f12` and `fc2f5b9f` touched
  `pkgs/labs/rust-tictactoe/default.nix`, but the package is Abird-only and was
  not adopted locally.
- Nixbot console coloring: `bf51766f` and `ce6220c4` were adopted for shared
  nixbot code and tests.
- Kanidm auto-apply stamps: `b4bbd2a8` was adopted for the shared
  `lib/services/kanidm` helper. The Abird helper file is byte-identical, and the
  local docs now include the previously indexed Kanidm note.
- Image pin policy: the general image-reference rule from `446992e9` was adopted
  in the local Podman Compose design pattern.
- Host service image pins: `677b95c4` and the host-specific service file changes
  from `446992e9` were skipped because they target `gap3-rivendell` and
  `abird-corp`, not local PVL host services.

## Commit Ledger

| Commit     | Subject                                   | Disposition                                                                                                                                                         |
| ---------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `446992e9` | `fix(abird-corp): pin service images`     | Partially adopted. The shared image pin design rule was ported; Abird host service pins and OpenDesign/Open WebUI incident notes were skipped as topology-specific. |
| `677b95c4` | `fix(gap3-rivendell): pin service images` | Skipped. The changes are Gap3 host service image pins and Open WebUI database repair specific to that host shape.                                                   |
| `ce6220c4` | `style(nixbot): soften warning yellow`    | Ported cleanly in `pkgs/tools/nixbot/{nixbot.sh,tests/test_nixbot.py}`.                                                                                             |
| `b4bbd2a8` | `fix(kanidm): canonicalize apply stamps`  | Ported cleanly in `lib/services/kanidm/helper.sh`; adopted the shared Kanidm note for semantic auto-apply stamp guidance.                                           |
| `fc2f5b9f` | `fix(rust-tictactoe): add lint compiler`  | Skipped. `pkgs/labs/rust-tictactoe` is Abird-only and is not part of the local package set.                                                                         |
| `bf51766f` | `fix(nixbot): color failed output`        | Ported cleanly in `pkgs/tools/nixbot/{nixbot.sh,tests/test_nixbot.py}`.                                                                                             |
| `b0d00f12` | `fix(rust-tictactoe): update cargo hash`  | Skipped. `pkgs/labs/rust-tictactoe` is Abird-only and is not part of the local package set.                                                                         |

## Byte-Parity Targets

The shared byte-parity set for this audit is:

- `lib/services/kanidm/helper.sh`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

## Intentional Divergences

- `hosts/gap3-rivendell/**` and `hosts/abird-corp/**` were not copied. Those are
  environment-specific service image pins and bootstrap repairs for other
  topologies.
- `pkgs/labs/rust-tictactoe/**` was not copied. The lab package is Abird-only
  and is intentionally absent from the local package manifest.
- Abird's OpenDesign and Open WebUI incident notes were not copied because the
  local PVL Open WebUI modules do not contain the SQLite preStart repair shape,
  and the OpenDesign image exception is specific to Abird's service.

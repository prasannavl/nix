# Abird Latest Post-19c Port 2026-07

Reviewed the newest five commits on `abird/master` after `19c57198`, ending at
`bd552f84`, from local base `caa46e6a`.

## Logical Units

- PVL-origin update report tooling: `71c79bb6` was already present locally with
  byte-identical files.
- NVIDIA driver pin: `ea3ccdf2` was already present locally with byte-identical
  package pin data.
- Nixbot test runtime: `dca65a2b` was already present locally with
  `pkgs.util-linux` in the nixbot helper test derivation.
- Abird tooling docs: `bb0b832e` records a PVL port audit inside Abird's docs
  tree and was not copied.
- Nixbot build-log noise trimming: `bd552f84` was adopted for shared nixbot code
  and tests.

## Commit Ledger

| Commit     | Subject                                | Disposition                                                                                                                 |
| ---------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `bd552f84` | `fix(nixbot): trim build log noise`    | Ported cleanly in `pkgs/tools/nixbot/{nixbot.sh,tests/test_nixbot.py}`.                                                     |
| `bb0b832e` | `docs(tooling): record pvl port audit` | Skipped direct copy. It is Abird's record of importing PVL work; this note is the local equivalent for the follow-up audit. |
| `dca65a2b` | `test(nixbot): add flock runtime`      | Already present locally; `pkgs/tools/nixbot/tests/default.nix` is byte-identical to `abird/master`.                         |
| `ea3ccdf2` | `chore(nvidia): bump driver pin`       | Already present locally; `lib/ext/nvidia/default.nix` is byte-identical to `abird/master`.                                  |
| `71c79bb6` | `fix(update): sync pvl report tooling` | Already present locally; report tooling and VS Code update helper files are byte-identical to `abird/master`.               |

## Byte-Parity Targets

The shared code parity set for this audit is:

- `lib/ext/nvidia/default.nix`
- `lib/ext/vscode/update.sh`
- `scripts/support/report-podman-images.py`
- `scripts/support/tests/test_report_podman_images.py`
- `pkgs/tools/nixbot/tests/default.nix`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

## Intentional Divergences

- Abird's `.agents/docs/notes/tooling/pvl-last50-port-2026-07-12.md` and related
  docs index churn were not copied. This repo keeps the follow-up audit in this
  Abird-port note instead.

# Abird Latest Post-4b6d Port 2026-07

Reviewed the newest 10 commits on `abird/master` after `4b6d3859`, ending at
`07375d74`, from local base `373b5881`.

## Logical Units

- Abird ACME topology ordering: `ae4013ec` is Abird host topology and was not
  ported.
- Podman Compose explicit image pulls and convergence hardening: `9222a598`,
  `231384f9`, `53ebde76`, `53223166`, and `93cf8352` were adopted for shared
  code, tests, and locally scoped docs.
- Abird shared artifact cache plan: `fac3416b` is Abird infra planning and was
  not ported.
- Nixbot deploy progress and console normalization: `b8e5d734`, `b64cba39`, and
  `07375d74` were adopted for shared nixbot code, tests, and local docs.

## Commit Ledger

| Commit     | Subject                                          | Disposition                                                                                                                                              |
| ---------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `07375d74` | `fix(nixbot): avoid repeated host names`         | Ported cleanly in `pkgs/tools/nixbot/{nixbot.sh,tests/test_nixbot.py}`.                                                                                  |
| `b64cba39` | `feat(nixbot): trim deploy console noise`        | Ported shared console-normalization code and tests; skipped Abird consolidated docs.                                                                     |
| `b8e5d734` | `feat(nixbot): improve deploy progress`          | Ported verify-job health fanout, deploy progress formatting, and tests; adapted the health-check fanout note locally.                                    |
| `fac3416b` | `docs(infra): plan shared artifact cache`        | Skipped. The plan is Abird-specific infra strategy; any PVL cache plane should be designed as a separate local plan.                                     |
| `93cf8352` | `style(docs): format podman compose notes`       | Adopted through locally formatted podman-compose notes.                                                                                                  |
| `53223166` | `fix(podman-compose): harden convergence checks` | Ported shared helper PATH, rootless idmap preflight, verify transition failure, stop cleanup semantics, module tests, and helper tests.                  |
| `53ebde76` | `style(podman-compose): format pull helper`      | Ported as part of byte-identical `lib/podman-compose/image-pull-all.sh`.                                                                                 |
| `231384f9` | `fix(podman-compose): quiet skipped pulls`       | Ported quiet skip accounting in `helper.sh`, `image-pull-all.sh`, and tests; adapted pull-sidecars docs.                                                 |
| `9222a598` | `fix(podman-compose): gate image pulls`          | Ported image-pull stamp gating, declared image extraction, fatal pull-output detection, retry behavior, status markers, fake Podman coverage, and tests. |
| `ae4013ec` | `fix(abird): keep ACME out of user graph`        | Skipped. It modifies Abird host ACME/bootstrap wiring and Abird docs only; no shared PVL module change was present.                                      |

## Byte-Parity Targets

The shared code parity set for this port is:

- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/podman-compose/image-pull-all.sh`
- `lib/podman-compose/tests/fake_podman.py`
- `lib/podman-compose/tests/module.nix`
- `lib/podman-compose/tests/test_helper.py`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

## Intentional Divergences

- `pkgs/tools/nixbot/tests/default.nix` keeps the local `pkgs.util-linux`
  dependency so the sandboxed nixbot tests have `flock`.
- `.agents/docs/**` is adapted to this repo's docs structure instead of copying
  Abird consolidated notes and broad docs index churn.
- `.agents/plans/abird-shared-artifact-cache-plane-2026-07.md` was skipped as
  Abird infra planning.
- `hosts/abird-*` and `hosts/common/abird.nix` changes from `ae4013ec` were
  skipped as Abird topology.

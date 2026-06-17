# Abird Last-30 Port, 2026-06-17

## Scope

- Local start: `e512b1c7 update(flake): p7 ext`.
- Source: `abird/master~30..abird/master`, ending at
  `c561d5a4 style(lint): fix pre-push warnings`.
- Goal: port shared units from Abird while keeping local PVL host/input
  differences explicit.

## Ported Or Adopted Units

- Machine profiles:
  - adopted Abird's split between flake profiles and machine profiles
  - kept this repo's local input set (`antigravity`, `p7-*`, `noctalia`,
    `llm-agents`)
  - moved Incus guest bootstrap into `lib/profiles/incus-lxc.nix` and
    `lib/profiles/incus-vm.nix`
  - set physical PVL hosts to `machineProfile = null`
- Migration manager:
  - renamed `lib/services/migrator` to `lib/services/migration-manager`
  - updated `lib/flake/service-module.nix`,
    `lib/systemd-user-manager/default.nix`, and `data-migrator` references
  - adapted `data-migrator` to create the renamed service-owned directory before
    writing bootstrap host state
- Shared service helpers:
  - adopted `services.activesync` option naming
  - adopted `lib/services/tunnels/{tailscale,wg}.nix`
  - adopted `lib/services/tunnels/wg-helper.sh`
- Incus/Podman:
  - adopted LXC mount-interception defaults in `lib/incus/lib.nix`
  - adopted matching Podman LXC overlay/FUSE handling in `lib/podman.nix`
- Tooling:
  - adopted `pkgs/ext/gcp-vms/iap-ssh.sh`
  - adopted `scripts/lint.sh` host-eval parallelism
  - adopted the reusable nixbot target-local rollback runner plan doc

## Per-Commit Disposition

| Commit     | Subject                                          | Disposition                                                                                                                          |
| ---------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `93b3997c` | `fix(nixbot): discover terraform tfvars`         | Already ported logically; repo-relative tfvars discovery was present locally, doc already aligned.                                   |
| `194e8182` | `docs(hosts): record abird-labs LXC failure`     | Skipped; Abird host incident note.                                                                                                   |
| `ed6ad53b` | `style(docs): format deploy notes`               | Skipped; Abird doc-only formatting outside shared local docs.                                                                        |
| `4da51dcd` | `style(stalwart): group service attrs`           | Skipped; Abird host service formatting.                                                                                              |
| `69402c67` | `style(edge): group service attrs`               | Skipped; Abird host formatting.                                                                                                      |
| `416e22e5` | `feat(gcp-vms): add IAP SSH helper`              | Adopted `pkgs/ext/gcp-vms/iap-ssh.sh`; adapted local playbook text without Abird-specific host examples.                             |
| `ac1ef756` | `refactor(wg): share edge tunnel helpers`        | Adopted shared `lib/services/tunnels/wg.nix` and `wg-helper.sh`; skipped Abird host and secret moves.                                |
| `9fdc2c5d` | `fix(wg): pin networkd secret paths`             | Adopted shared `lib/services/tunnels/wg.nix` secret path support; skipped Abird host and secret path changes.                        |
| `cde57094` | `fix(nixbot): fail switch transport loss`        | Adopted; `pkgs/tools/nixbot/nixbot.sh` now matches Abird byte-for-byte.                                                              |
| `982a7aed` | `chore(hosts): move edge hosts to next`          | Skipped; Abird host profile selection.                                                                                               |
| `e0ad6efe` | `style(wg): satisfy statix`                      | Adopted through byte-identical `lib/services/tunnels/wg.nix`.                                                                        |
| `26c9c231` | `fix(migrator): select manifest units correctly` | Already ported; `pkgs/tools/migrator/{migrator-helper.sh,test_migrator_helper.sh}` were byte-identical.                              |
| `07674400` | `feat(hosts): select next Abird profiles`        | Skipped; Abird host profile selection.                                                                                               |
| `9307f876` | `fix(tictactoe): update vendor hash`             | Skipped; Abird-only `pkgs/labs` package is absent locally.                                                                           |
| `41cdabeb` | `docs(hosts): record labs recovery`              | Skipped; Abird host recovery note.                                                                                                   |
| `8f4c732f` | `feat(hosts): select next Gap3 profiles`         | Skipped; Abird/GAP3 host profile selection.                                                                                          |
| `535a51cf` | `fix(nixbot): retry bad fd transport`            | Already ported logically through local nixbot commits; not byte-identical because local follow-ups differ.                           |
| `85e0802d` | `feat(nixbot): fail fast deploy waves`           | Already ported logically through local nixbot commits; not byte-identical because local follow-ups differ.                           |
| `73009eb7` | `feat(nixbot): cache host build plans`           | Already ported logically through local nixbot commits; `lib/flake/root.nix` adapted to local input profile shape.                    |
| `e7bc76f0` | `docs(nixbot): plan target rollback runner`      | Adopted `.agents/docs/plans/nixbot-target-local-rollback-supervisor-2026-06.md`.                                                     |
| `abcf78af` | `refactor(incus): split guest profiles`          | Adopted with local adaptation: PVL hosts kept, physical hosts opt out of machine profile, Incus hosts use central profile selection. |
| `ceb05461` | `fix(incus): avoid LXC mount interception`       | Adopted shared `lib/incus/lib.nix` and `lib/podman.nix`; skipped Abird host call-site cleanup.                                       |
| `3f3c3420` | `refactor(activesync): rename service option`    | Adopted shared module rename to `services.activesync`; skipped Abird host consumers.                                                 |
| `994e2035` | `refactor(migration): rename manager module`     | Adopted migration-manager path rename and references; content stayed equivalent under the new path.                                  |
| `f176f113` | `fix(tailscale): handle null auth keys`          | Adopted through `lib/services/tunnels/tailscale.nix`.                                                                                |
| `837b2ab7` | `refactor(users): drop substrate aliases`        | Skipped; Abird user/host alias cleanup.                                                                                              |
| `3faa4569` | `refactor(profiles): own SSH defaults`           | Adopted through the machine profile adaptation; skipped Abird host-only removal.                                                     |
| `29fbafdd` | `refactor(flake): select machine profiles`       | Adopted with local `flakeProfile`/`machineProfile` adaptation; kept repo-specific extra inputs.                                      |
| `26366339` | `perf(lint): parallelize host evals`             | Adopted `scripts/lint.sh` host-eval parallelism.                                                                                     |
| `c561d5a4` | `style(lint): fix pre-push warnings`             | Adopted the lint-script cleanup; skipped Abird host/package style fallout.                                                           |

## Intentional Divergences

- `lib/flake/root.nix` is adapted, not byte-identical, because this repo has
  additional local flake inputs and PVL-only host inventory.
- `pkgs/tools/data-migrator/{data-migrator.py,test_data_migrator.py}` carry a
  missing parent-dir creation fix that was exported back to the Abird worktree
  so the two working copies are byte-identical.
- Abird host, secret, Terraform, and stack docs were skipped unless the commit
  introduced a reusable helper under `lib/` or `pkgs/`.

## Parity Targets

The following files are intended to stay byte-identical with `abird/master`
after formatting:

- `lib/incus/lib.nix`
- `lib/podman.nix`
- `lib/profiles/incus-lxc.nix`
- `lib/profiles/incus-vm.nix`
- `lib/profiles/vm.nix`
- `lib/services/activesync/default.nix`
- `lib/services/machine-id/default.nix`
- `lib/services/migration-manager/bootstrap-hosts.nix`
- `lib/services/migration-manager/default.nix`
- `lib/services/migration-manager/options.nix`
- `lib/services/tunnels/tailscale.nix`
- `lib/services/tunnels/wg-helper.sh`
- `lib/services/tunnels/wg.nix`
- `pkgs/ext/gcp-vms/iap-ssh.sh`
- `pkgs/tools/data-migrator/data-migrator.py`
- `pkgs/tools/data-migrator/test_data_migrator.py`
- `pkgs/tools/nixbot/nixbot.sh`
- `scripts/lint.sh`

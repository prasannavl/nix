# Abird Post-44DF Port, 2026-07

## Scope

- Local pre-port baseline: `583a38b4` on `master`.
- Previous completed Abird audit tip: `44dfc80f`.
- Refreshed Abird source tip: `af4cf51f`.
- Audit window: `44dfc80f..af4cf51f`, 28 commits in source order.
- Port worktree: `worktrees/abird-recent-port-20260729`.

Every source commit was reviewed before grouping the reusable changes. Whole
commit patch IDs were treated as supporting evidence only; split local commits,
repository-owned docs, and topology policy make resulting file bytes the
stronger parity signal.

## Per-commit ledger

| Commit     | Subject                                          | Disposition                                                                                                                                                                                                              |
| ---------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `edd401e6` | `build(flake): sync shared input pins`           | Already adopted and later refreshed locally. The final shared root `nixpkgs`, `unstable`, and `vscode-ext` lock objects match; the complete lock topology remains repository-owned.                                      |
| `4ee0065f` | `fix(nvidia): preserve CDI generator`            | Already adopted by local `26e2ecf6`; `lib/hardware/nvidia.nix` is byte-identical.                                                                                                                                        |
| `78e280cc` | `style(stalwart): normalize compat patches`      | Already adopted in local `09d7c73d`; both Stalwart compatibility patches are byte-identical.                                                                                                                             |
| `2806781b` | `style(docs): scope duplicate headings`          | Already adopted exactly as local `05215557`, including a matching stable patch ID.                                                                                                                                       |
| `ef693dc3` | `docs(tooling): record port audit`               | Skipped. This is Abird-owned bookkeeping for a Pvl-to-Abird port; this ledger is the local audit record.                                                                                                                 |
| `0f54349e` | `build(flake): refresh inputs`                   | Already adopted through local lock refreshes. Shared resolved inputs match; extra local root inputs and lock-node structure are retained.                                                                                |
| `d00cd3b1` | `chore(ext): update pinned tools`                | Already adopted by local `9d92db32`, `67c89b97`, and `1d575fc6`; Stalwart CLI, Tailscale, and VS Code definitions are byte-identical.                                                                                    |
| `103ffb84` | `build(flake): refresh inputs`                   | Already adopted within local `130432a6`; final shared root input objects match exactly.                                                                                                                                  |
| `d487c144` | `chore(abird-nest): disable replicas`            | Skipped. Abird Nest topology is absent locally, and this intermediate commit also used invalid Nix comment syntax.                                                                                                       |
| `b588df4b` | `fix(abird-nest): correct comment syntax`        | Skipped with the absent Abird Nest topology; it only repairs the preceding source-owned file.                                                                                                                            |
| `39938845` | `docs: plan agentic app platform`                | Skipped. The plan is for the Abird-branded application and has no local package or runtime consumer.                                                                                                                     |
| `20dec9a4` | `feat(stacks): add stack-set composition`        | Cleanly ported as a shared `lib/flake` unit. `service-registry.nix` and the final `stack-set.nix` state are byte-identical; stack-family addressing, secrets, and projections remain repository-owned.                   |
| `8ccdb76c` | `feat(stacks)!: add Abird platform plane`        | Skipped. Abird platform profiles, hosts, project topology, and stack inventory are source-owned.                                                                                                                         |
| `52d6725f` | `fix(incus): publish delegation before setup`    | Already adopted by local `6ee057b7` with code/test patch parity and locally adapted documentation in `03152dc4`. Current helper and tests are byte-identical.                                                            |
| `e806357e` | `feat(abird-nest): provision platform stack`     | Skipped. The nested Abird controller configuration is absent locally; parent-side ownership remains under `hosts/pvl-x2`.                                                                                                |
| `f8d9ff4f` | `feat(nixbot): derive platform inventory`        | Skipped. The workflow, host module, and host-manager policy encode Abird/Gondor inventory. Local host-manager policy intentionally owns Pvl selection.                                                                   |
| `0f7ca240` | `chore(migration): retain Gondor CI and dev`     | Skipped. Both changes are Abird/Gondor migration inventory: retained guests were removed from the source profile set and migration script. The obsolete local Abird profile inventory was retired independently.         |
| `b127d5af` | `fix(nixbot): wait for queued user starts`       | Cleanly ported byte-for-byte in nixbot and its tests. The local health note records the generic queued-job contract without the source incident wording.                                                                 |
| `75084481` | `docs(abird): record platform bootstrap`         | Skipped directly. Abird rollout plans and topology notes remain source-owned; the generic stack-set ownership boundary is documented locally with the shared composition unit.                                           |
| `87d98aca` | `style(stacks): satisfy statix`                  | Cleanly ported with `20dec9a4` by taking the finalized `stack-set.nix` bytes.                                                                                                                                            |
| `cd4bc8a5` | `feat(agentic): add shared UI and desktop shell` | Skipped. The Leptos UI, Tauri shell, Cargo workspace entries, manifest exports, and branding implement an Abird product rather than reusable infrastructure.                                                             |
| `1a5facc2` | `docs(agentic): record Phase 1 foundation`       | Skipped with the absent Abird application and plan.                                                                                                                                                                      |
| `05c67c00` | `fix(agentic): align desktop package checks`     | Partially adopted and corrected. The generic `projectPath` split was ported, then `sourcePath` was aligned with the owning package rather than a nested crate. Abird application changes and product notes were skipped. |
| `96d44c09` | `fix(lint): clean package op temp dirs`          | Adopted and corrected locally. Manifest commands preserve status and run in an extra child subshell so an operation using `exec` cannot bypass temporary-directory cleanup. A regression check covers the failure path.  |
| `c60d5a5e` | `feat(incus): reconcile instance limits`         | Already adopted by local `0d644754` and `6e1076c7`. Five implementation/test files are byte-identical; local `tests/module.nix` retains its equivalent target-newer Statix-safe expression shape.                        |
| `c81de611` | `feat(stacks): add Incus resource budgets`       | Skipped exact files. They encode Abird/GAP3 roles, addresses, and budgets; local physical envelopes are owned by `71761cd2` under `hosts/pvl-x2`.                                                                        |
| `dcec0e21` | `docs(incus): record limit boundaries`           | Already adopted and adapted by local `c43ae1e2` plus `f19e2f84`, with local physical and nested-controller wording retained.                                                                                             |
| `af4cf51f` | `feat(network): add host traffic shaping`        | Already adopted by local `c74a9fa5`. All six shared implementation/test files are byte-identical; the source generic note is covered and expanded by the local Pvl-x2 ownership note.                                    |

## Logical port units

1. Generic multi-stack composition and per-role endpoint overlays under
   `lib/flake`.
2. Nixbot post-switch health handling for exact queued user start jobs, with
   byte-identical tests and adapted local documentation.
3. Rust package-operation ownership through an explicit `projectPath` distinct
   from a nested crate's `projectDir`, including matching package-owner
   `sourcePath` metadata.
4. Explicit manifest-operation temporary-directory cleanup in the lint runner,
   with an `exec`-path regression check.
5. Residual shared-package parity: the Cloudflare child-flake wrapper now relies
   on the centralized dev-shell export, and both Cloudflare application notes
   describe the canonical `default.nix` prebuild path while retaining local
   encrypted-input locations.
6. This exhaustive audit ledger and the relevant shared design documentation.

## Local ownership correction

Independently of the source commit window, the obsolete Abird-only local
data-migrator inventory was retired by setting `profiles.nix` to `{}`. The
shared migrator remains available, but concrete plans now require explicit YAML
and path bases; operator documentation no longer publishes Abird hostnames,
paths, projects, or controller policy.

## Parity contract

After the port, 313 of the 337 files present in both trees under `lib/**` and
`pkgs/**` are byte-identical. The finalized stack-set file is included in that
count. Stack composition, nixbot, its tests, and the Cloudflare child-flake
wrapper exactly match `abird/master` at `af4cf51f`. The package helper and lint
runner intentionally advance beyond source parity to close review-discovered
correctness gaps.

The remaining 24 differences are intentional or target-newer:

- root flake, host defaults, image inventory, installer defaults, stack index,
  and other repository-owned NixOS policy;
- target-newer package-helper ownership behavior, stack-set and lint regression
  coverage, and the equivalent Incus module-test expression;
- package catalog and encrypted Cloudflare application documentation;
- package manifest membership;
- NATS stream inventory, the generic local data-migrator policy, documentation,
  and path-base guard, and host-manager policy.

Source-only Abird application, bot, lab, service, and topology packages were not
counted as shared merely because they live under `pkgs/`. No shared
`lib/systemd-user-manager`, Podman Compose, service helper, Incus
implementation, external package definition, or host-network-QoS implementation
drift remains from this audit window.

The broad parity pass also recovered a pre-existing portable drift outside the
28-commit window: `pkgs/cloudflare-apps/llmug-hello/flake.nix` now matches the
centralized child-flake wrapper introduced by source commit `a73ef2e8`. The
associated package and Terraform documentation was adapted to the current nixbot
`default.nix` build contract without importing Abird's plaintext tfvars layout.

## Validation

- Refetched `abird/master` after the implementation pass and confirmed the tip
  remained `af4cf51f` with exactly 28 commits after `44dfc80f`.
- Ran all 176 nixbot unit tests, including queued-start acceptance and unrelated
  job rejection.
- Built the stack-set composition fixture, nested Rust package-owner fixture,
  and manifest temporary-directory cleanup regression check.
- Built the data-migrator helper test after retiring the concrete profiles and
  requiring explicit file-copy path bases.
- Evaluated the Pvl service registry and the Cloudflare child-flake development
  shell.
- Passed the repository diff lint gate, including root output checks and all
  seven changed-host evaluations.
- Confirmed the main worktree remained clean before promotion and made no live
  deployment changes.

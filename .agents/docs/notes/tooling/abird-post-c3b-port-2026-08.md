# Abird Post-c3b Port, 2026-08

## Scope

- Pvl pre-audit tip: `27160fe9581d082f9a376be7a0f071df43b181aa` on the primary
  `master` worktree.
- Previous completed Abird audit tip:
  `c3b359045911f122de43abec2cac242b06bdbc4a`.
- Frozen Abird local `master` tip: `f8c4a41b169bedb47cf093423879d9f80af747a5`.
- Frozen Abird tracking and live GitHub tip:
  `2a22a5e443bd04cb0421fbe7cecb69ce8f9fee6d`.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

Abird had diverged after the common dependency-refresh commit `c16e85f4`: local
`master` was four commits ahead and two behind `origin/master`. The audit
therefore froze and classified the union of both lines: seven unique commits
after `c3b35904`, with no invented linear order between the two sides of the
fork.

Pvl already contained a mixed staged and unstaged Incus port when this audit
started. That state was preserved. Three parallel read-only reviews inspected
the local line, the remote-only line, and the exact Incus overlap before the
remaining shared lock node and documentation gap were ported.

## Per-Commit Ledger

|  # | Branch | Commit     | Subject                                     | Final disposition                                                                                                                                                                                                                                                                                                                                                                              |
| -: | ------ | ---------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | common | `c16e85f4` | `build: refresh dependencies`               | Adopted. Pvl `27160fe9` already carried byte-identical NVIDIA, Tailscale, and VS Code pins plus the same `nixpkgs` and `vscode-ext` lock nodes. This port adds the one missing shared `unstable` node at `83199d0d`. The complete Abird lockfile is skipped because the repositories have different input graphs.                                                                              |
|  2 | local  | `3e146328` | `fix(incus): harden guest lifecycle`        | Cleanly ported before this audit. All six shared implementation and test files are byte-and-mode exact, their Pvl base blobs match the source parent, and the cumulative stable patch ID is `4a8bcbc5cb515f162218d4d28478ac77caa61d72`. No reapplication was performed.                                                                                                                        |
|  3 | local  | `23531b20` | `fix(abird-dev): satisfy Incus admission`   | Adapted. Its four source paths are absent Abird topology. Pvl owns the parent project and already declares the 32 GiB root-profile and custom-volume defaults. The generic `stateVolumeSize` API arrived with `3e146328`; Abird alone projects it into its guests. Pvl keeps `gap3-gondor`'s valid `-250` OOM adjustment while documenting why restricted `abird-dev` guests omit the setting. |
|  4 | local  | `b66b62da` | `fix(abird-platform): allow CI cache`       | Adapted. The Abird stack declaration is absent, while Pvl's parent fabric now materializes its resolved effect: `abird-platform` may reach `10.10.30.80` on TCP 5000. Pvl's adjacent TCP 22 exception for delegated readiness is an intentional parent-owned addition.                                                                                                                         |
|  5 | local  | `f8c4a41b` | `docs(incus): record Nest recovery`         | Adapted. The Abird platform note is skipped; route restart coupling, admission ordering, storage sizing, cache and SSH policy, and the low-level-container restriction are recorded in Pvl's existing Incus notes and canonical index.                                                                                                                                                         |
|  6 | origin | `2cf06a09` | `docs(plan): derive goals from user intent` | Skipped. It changes only Abird's durable-agency product plan, which has no Pvl counterpart.                                                                                                                                                                                                                                                                                                    |
|  7 | origin | `2a22a5e4` | `fix(agent): harden single-prompt goals`    | Skipped. Its UI, orchestration, provider, browser, desktop, and plan-history units belong to absent `pkgs/apps/abird-app`, `pkgs/srv/abird-agent`, and `pkgs/web/abird-web` product packages. It does not touch the shared host agent or host manager.                                                                                                                                         |

## Logical Units

### Shared dependency refresh

The common package pins are already exact. Pvl adopts only the missing
`flake.lock` `unstable` node:

- revision `83199d0d373dd3ac2b9a1996b1d0263f76ab7a4c`;
- NAR hash `sha256-VYXO0XZlgj06dxJZRhrD3WoSsvq/c7+/Akyoa22pefw=`.

The root lockfiles remain repository-owned because their input graphs differ.

### Shared Incus lifecycle and admission

The byte-identical `3e146328` unit:

1. restarts machine lifecycle units when the shared helper changes, stops and
   re-pulls autostart targets and gates during reconfiguration, and couples the
   route reconciler to `incus.service`;
2. supplies CPU and memory limits at instance creation and defers only the
   specific not-yet-attached profile-device limit error;
3. carries an optional state-volume size through `mkLxc`, applies explicit or
   pool-default size at custom-volume creation, and removes the creation-only
   property before disk attachment;
4. extends the fake Incus CLI and helper/module regressions for each behavior.

Exact shared files:

| Mode     | Blob       | Path                             |
| -------- | ---------- | -------------------------------- |
| `100644` | `6faf4e17` | `lib/incus/default.nix`          |
| `100644` | `77b399f0` | `lib/incus/helper.sh`            |
| `100644` | `34042fb5` | `lib/incus/lib.nix`              |
| `100644` | `ef39702b` | `lib/incus/tests/fake_incus.py`  |
| `100644` | `5deb20c6` | `lib/incus/tests/module.nix`     |
| `100644` | `d28334c9` | `lib/incus/tests/test_helper.py` |

### Split topology ownership

Abird owns guest-stack intent and Nest's delegated controller. Pvl owns the
physical Incus project, profile and pool sizing, routes, and parent-fabric
forward policy. The two repositories therefore carry different literal paths for
the same end-to-end recovery contract; copying either topology into the other
would violate the established ownership boundary.

### Abird product goals

The remote-only goal-plan and single-prompt hardening commits form one Abird
desktop/web/controller product vertical. Pvl has no consumer for an extracted
provider or orchestration fragment, so the complete unit remains excluded.
`pkgs/srv/abird-agent` is distinct from the shared host-local
`pkgs/tools/abird-host-agent`.

## Parity Contract

Against frozen Abird local `f8c4a41b`, 402 tracked paths are common under
`lib/**` and `pkgs/**`: 382 are byte-and-mode exact, the same 20 established
Pvl-owned content divergences remain, and there are zero mode differences.

Against live Abird `origin/master` at `2a22a5e4`, 376 of the same 402 paths are
exact. The additional six differences are precisely the local-only Incus unit
already ported to Pvl; the remote-only product commits change no common
implementation path.

The shared host-agent tree remains exact at
`f97ddff90ae522967518951de33ab852fc068b02`. Neither branch changes the host
agent or host manager in this window. Every common host-manager path except its
previously documented repository-specific README remains exact.

## Validation

- The packaged Incus helper check passed all 20 tests.
- The packaged Incus module check passed.
- The complete `pvl-x2` NixOS system build passed with import from derivation
  disabled.
- The six shared Incus files match Abird local `master` byte-for-byte with
  matching modes and stable patch ID.
- The dependency pins and selected common lock nodes match the Abird refresh.
- The port was committed as dependency-ordered logical units. No push, deploy,
  or persistent live mutation was performed.

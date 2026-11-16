# Abird tail audit — 2026-11-16

Audit of Abird work created after the follow-up port boundary. Status: nothing
to port; one shared guidance document aligned. No push, deployment or secret
access.

## Boundary

- Source: Abird `master` `d968b3885`, window `c735a7247..d968b3885` — 9 linear
  commits, no merges.
- Destination: nix `master` `0dabd48b8`.
- `c735a7247` is the source tip of the [follow-up port](README.md); every commit
  in this window was created after that port's tree snapshot.
- Abird holds the destination tail `40dac5f5f..0dabd48b8` (5 commits) only on
  its `pvl/master` remote ref; it is not merged into Abird `master`.

## Per-commit disposition

| Commit      | Subject                                         | Disposition                                                                                                                                                                                            |
| ----------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `be75546ca` | fix(backup): remove retired readers             | Skipped — 29 encrypted Abird credential files (`data/secrets/abird/**`, `data/secrets/globals/recovery/**`). No destination counterpart; contents not read.                                            |
| `1fdcdbb61` | fix(backup): remove retired declarations        | Skipped — Abird host/secret product state (`hosts/abird-srv`, `hosts/gap3-gondor`, epoch 7–12 reader modules). Destination has none of these paths; `data/secrets/default.nix` lacks the removed hunk. |
| `cbc5ec6b3` | docs(backup): record reconciled cleanup         | Skipped — Abird plan/work/note state only.                                                                                                                                                             |
| `73b93f73a` | feat(tailscale): pin 1.104.6                    | Already adopted — `lib/ext/tailscale/sources.nix` byte-identical (1.104.6, same src/vendor hashes); `unstable` pin equal, Go 1.27.3 satisfies the pin.                                                 |
| `cf81ed2de` | chore(deps): align shared inputs upstream       | Already adopted — all nine shared root inputs sit on identical rev, narHash and `follows` edges; Abird is ahead on nothing.                                                                            |
| `004c05c66` | test(flake): port real-Crane integration checks | Already adopted — the destination `lib/flake/tests/pvl/*` set is the source of these files. `external-packages.nix` byte-equal; the three rust integration checks differ only in derivation name.      |
| `6cf55431e` | feat(overlays): pin tmux-resurrect              | Already adopted — destination created the overlay on 2026-10-05 (`bedf261a9`, `c2aa4b0b7`); logic equal, Abird dropped a destination-only comment reference.                                           |
| `569752726` | refactor(lib): drop unused sway module          | Already adopted — no `lib/sway.nix` and no reference to it; `lib/wm.nix` supersedes it.                                                                                                                |
| `d968b3885` | docs: record shared port follow-up              | Partially adopted — see below.                                                                                                                                                                         |

## Adopted from `d968b3885`

| Path                                                    | Action                                                                                                                                                                                                                           |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.agents/docs/lang-patterns/nix.md`                     | Adopted the reworded `path:` bullet plus the repo-neutral rules the file had drifted on (attrset consolidation, `s.srv.trackedPath`, Git-aware flake refs and wrapper entrypoints, canonical child imports, child-lock wording). |
| `.agents/docs/design-patterns/external-source-units.md` | Already byte-equal; no change.                                                                                                                                                                                                   |
| `pkgs/README.md` (GCP VM bullet)                        | Already byte-equal; no change.                                                                                                                                                                                                   |
| `.agents/docs/notes/tooling/pvl-port-2026-11/*`         | Skipped — Abird-side mirror ledger; this directory is the destination record.                                                                                                                                                    |

Retained in the guidance doc: the destination-only "parenthesize function
applications" rule and the omission of Abird's `overlays/rust-policy.nix`
Design-L paragraph, which describes a policy the destination does not have.

## Parity snapshot (type, bytes, mode, link target)

| Tree         |    Equal |   Common |       % | Only nix | Only Abird |
| ------------ | -------: | -------: | ------: | -------: | ---------: |
| `lib/`       |      547 |      561 |     97% |       49 |         53 |
| `pkgs/`      |      486 |      503 |     97% |        2 |        478 |
| `overlays/`  |        2 |        5 |     40% |        6 |          1 |
| `scripts/`   |       27 |       31 |     87% |        1 |          8 |
| `.githooks/` |        1 |        1 |    100% |        0 |          0 |
| `tf/`        |       56 |       84 |     67% |        1 |          4 |
| **Total**    | **1119** | **1185** | **94%** |   **59** |    **544** |

38 shared files differ with no mode-only difference. Every remaining difference
is one of:

- **Local policy.** `lib/{hardware,locale,network,nix,sudo,systemd}.nix`,
  `lib/installer/config/default.nix`,
  `lib/services/nix-builder-gc-coordination`, `lib/tests/default.nix`,
  `lib/flake/repo-checks.nix`, `overlays/{default,unstable}.nix`,
  `pkgs/{README,manifest}.nix`.
- **Child-flake workspace policy.** The 13 wrapper `flake.nix` files: Abird
  injects `rustWorkspaceDeps = false`, the destination keeps the shared default.
- **Identity areas.** `lib/flake/tests/pvl/*` versus `tests/abird/*` (derivation
  names, host fixtures, product registrations) and `lib/tests/pvl` /
  `scripts/qualification/rust/pvl`.
- **Retained qualification lane.** `lib/flake/rust/qualification/*` and
  `scripts/qualification/rust/*`: the destination keeps the optional patched
  Cargo lane. Abird retired it in `230f38141`; ledger row N222 records the skip
  reason (stock 1.95 ordering issue unresolved).
- **Infrastructure state.** `tf/` tfvars, zone/account/worker records, variable
  interfaces and the adapted `tests/test_variables.py`.
- **Abird-only product.** 544 paths (`pkgs/{srv,web,labs,bots,apps}`, `lib/ext`
  AI services, `lib/flake/tests/abird`, Abird support scripts).

## Unrequested observations

- `overlays/sway.nix` exists but its import is commented out in
  `overlays/default.nix`; `overlays/unstable-sys.nix` is likewise disabled. Not
  a parity gap.
- `pkgs/tools/codex-wrapper/` is the only destination-only package tree; Abird
  keeps 24 product packages instead.

## Verification

- `nix fmt` clean.
- `nix run .#lint -- --diff --base HEAD` pass (documentation-only change).
- Parity measured from `git archive` exports of both tips in scratch space.
- Not run: whole-system or image builds, fleet lint, deployments, live probes.

# Abird shared convergence audit after `28631f93`, 2026-09-22

## Authority and frozen boundaries

- Previous frozen Abird shared-port boundary:
  `28631f93bb660758f170164b61ac08b20c9838fa` (the tip recorded by
  [the post-`b8a766ed` parity repeat](./abird-post-b8a-parity-repeat-2026-09.md)).
- Configured `abird/master` tip at audit time: `857ac6eb`
  (`docs(ai): record runtimes membership port`).
- Pvl target: `master` = `origin/master` = `956e3564`
  (`docs(pi): record ollama-cloud model discovery`), clean working tree.
- Audit range: `28631f93..857ac6eb`, twelve linear commits.

Pvl and Abird are developed in lockstep on the shared `lib/**`, `pkgs/**`, and
`scripts/**` areas. Several of the twelve commits are the Abird-side mirror of
work that originated on the Pvl side earlier the same day, so this audit is a
byte-level convergence check rather than a fresh port.

## Every source commit

Status meanings: **ported** = every shared unit already byte-exact in Pvl;
**adopted** = Pvl carries the equivalent unit under its own identity commit;
**skipped** = source-only identity/product/docs with no Pvl unit.

|  # | Commit     | Subject                                          | Status  | Disposition                                                                                                                                                                                                                                                                                                       |
| -: | ---------- | ------------------------------------------------ | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `da93f3f0` | `test(nixbot): isolate parity ledger`            | adopted | Shared `pkgs/tools/nixbot/tests/test_nixbot.py` is byte-exact to Abird's post-split file. The new `test_nixbot_abird.py` is Abird identity; Pvl's identity sibling is `test_nixbot_pvl.py`.                                                                                                                       |
|  2 | `a56300c4` | `refactor(images): declare Incus profile`        | ported  | `lib/images/default.nix` byte-exact; explicit `machineProfiles.incusLxc` selection matches. Pvl counterpart removes stale kernel parameters (`6e9f32bb`).                                                                                                                                                         |
|  3 | `dee73503` | `docs(host-manager): separate topology`          | adopted | `pkgs/tools/abird-host-manager/README.md` byte-exact and generic; Pvl topology lives in its identity note (`2fc6cf93`). Abird-only note edits skipped.                                                                                                                                                            |
|  4 | `066a70ca` | `docs(parity): record phase one convergence`     | adopted | Pvl's own phase-one note records the same result (`bb5df99e`). Source-local ledger text skipped.                                                                                                                                                                                                                  |
|  5 | `181c69f3` | `docs(parity): record phase one publication`     | adopted | Pvl's own phase-one publication record (`7073da89`). Source-local publication history skipped.                                                                                                                                                                                                                    |
|  6 | `9c994747` | `refactor(nats): add stream-set factory`         | ported  | `pkgs/support/nats-streams/default.nix` byte-exact with the generic `mkStreamSet` factory. `lib/flake/tests/default.nix` is repository identity; `lib/flake/tests/abird/flake-isolated.nix` is identity-only. Pvl counterpart `3b81bcfa`.                                                                         |
|  7 | `bcbec080` | `feat(flake): compose repository modules`        | ported  | `lib/flake/repo-modules.nix`, `lib/flake/root.nix`, `lib/nix.nix`, `lib/flake/tests/repo-modules.nix`, and `lib/tests/default.nix` all byte-exact. Shared `flake.nix` wiring present. `lib/stacks/modules.nix` is repository identity; `chat-intelligence.nix` is Abird product-only. Pvl counterpart `ddece408`. |
|  8 | `bdb8234a` | `docs(parity): record module convergence`        | adopted | Shared `repository-module-composition.md` byte-exact and indexed; repository-specific note edits skipped in favor of Pvl's own (`a9f61f98`).                                                                                                                                                                      |
|  9 | `8f50849b` | `feat(ai): adopt membership-by-ref and runtimes` | ported  | All five `lib/services/ai/{catalog,default,module}.nix` and `tests/{lib,module}.nix` byte-exact. Pvl work originated here (`51d401ff`); Abird commit is the mirror.                                                                                                                                               |
| 10 | `51bae316` | `feat(prism-llama-cpp): vendor PrismML fork`     | ported  | All three `lib/ext/prism-llama-cpp/**` files byte-exact; both `prism-llama-cpp-rocm`/`-cuda` overlay exports present. Pvl counterpart `220ae3df`.                                                                                                                                                                 |
| 11 | `e833dd5b` | `refactor(abird-srv): select models by runtimes` | adopted | Abird host-only (`hosts/abird-srv/services/ai.nix`). Pvl's equivalent host projection is `d542f817` (`pvl-a1`/`pvl-l5` runtimes). No bundled shared change.                                                                                                                                                       |
| 12 | `857ac6eb` | `docs(ai): record runtimes membership port`      | adopted | Documentation only. Pvl carries its equivalent runtime/membership notes (`4428380b`). Abird-only note text skipped.                                                                                                                                                                                               |

Totals: six commits byte-exact at the shared level, four adopted under a Pvl
identity equivalent, two source-only documentation commits. No unexplained
source commit and no missing shared implementation.

## Logical units

### Test-area identity split

`da93f3f0` keeps the shared Nixbot test suite byte-identical and moves the
repository-specific Rust parity-ledger assertion into an identity sibling. Pvl
already applied that split in the opposite direction with `test_nixbot_pvl.py`.
The shared `test_nixbot.py` retains all runtime cases.

### Incus machine profile and stale kernel parameters

`a56300c4` names `machineProfiles.incusLxc` explicitly instead of inheriting a
root default, with no evaluated-behavior change. Pvl's phase-one counterpart
(`6e9f32bb`) removed obsolete commented kernel-parameter blocks. Both
repositories now carry byte-identical `lib/images/default.nix`; `lib/kernel.nix`
is byte-identical as well.

### Generic NATS stream-set factory

`9c994747` replaces repository-specific stream wiring with a generic
`mkStreamSet` factory in the shared package. Abird registers its
`chat-intelligence` streams, HTTP bridge, managed-secret assertions, and unit
ordering through the Gap3-only adapter
`pkgs/support/nats-streams/chat-intelligence.nix`. Pvl registers none and
selects the same byte-identical factory. The residual difference is repository
identity in `lib/stacks/modules.nix` only.

### Repository module composition

`bcbec080` introduces one validated named repository-module registry
(`lib/flake/repo-modules.nix`), a repository-provided `repoRegistry`, and a
composition-time `repoModulePkgs`. All generic files are byte-exact.
`flake.nix`, `lib/stacks/modules.nix`, and `lib/flake/tests/default.nix` differ
only in repository-owned inputs, registrations, and check names.

### AI membership-by-ref and PrismML fork runtime

`8f50849b` and `51bae316` are the Abird mirror of the Pvl-originated
membership-by-ref/runtimes model and the vendored PrismML ternary-GGUF
`llama.cpp` fork. Every shared AI module/test and every Prism package file is
byte-exact, and the overlay exposes both `rocm` and `cuda` variants. `e833dd5b`
is the Abird host projection; Pvl's host projection already exists.

## Shared parity inventory

Comparison of `master` (`956e3564`) against `abird/master` (`857ac6eb`) for all
tracked regular-file paths under `lib/**`, `pkgs/**`, and `scripts/**`:

| Metric                       | Count |
| ---------------------------- | ----: |
| Common paths                 |   541 |
| Exact content and mode       |   527 |
| Explained common differences |    14 |
| Mode differences             |     0 |
| Abird-only paths             |   307 |
| Pvl-only paths               |    44 |

Exact-set SHA-256 over sorted `path<TAB>mode<TAB>blob` lines without a trailing
newline: `0c01dd027ed9bc3ef9a5b0f208dc8fb44282ca454cddf2f7f568a477ae420bd2`.

### Explained common differences (14)

| Group                         | Count | Paths                                                                                                                                                                                                  |
| ----------------------------- | ----: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pvl platform/installer policy |     7 | `lib/ext/nvidia/sources.nix`, `lib/hardware.nix`, `lib/installer/config/default.nix`, `lib/locale.nix`, `lib/network.nix`, `lib/sudo.nix`, `lib/systemd.nix`                                           |
| Repository identity           |     7 | `lib/flake/repo-checks.nix`, `lib/stacks/default.nix`, `lib/stacks/modules.nix`, `pkgs/manifest.nix`, `pkgs/README.md`, `pkgs/cloudflare-apps/README.md`, `pkgs/cloudflare-apps/llmug-hello/README.md` |

All fourteen are intentional ownership boundaries, not unfinished ports. The
NVIDIA divergence is the established user-requested `595.91.07` rollback; the
rest are physical-host, installer, locality, network, privilege, suspend,
repository-check, stack, manifest, and README identity.

### Range-restricted classification

`git diff --name-status 28631f93..857ac6eb` restricted to `lib pkgs scripts`
yields eight additions and fourteen modifications:

- Every added/modified shared path is already common and byte-exact except
  `lib/stacks/modules.nix` (repository identity).
- Abird-only paths touched in the range are exactly three, all intentionally
  excluded: `lib/flake/tests/abird/flake-isolated.nix` (identity),
  `pkgs/support/nats-streams/chat-intelligence.nix` (Abird product adapter), and
  `pkgs/tools/nixbot/tests/test_nixbot_abird.py` (identity).
- Zero Abird-only paths in the range are generic/shareable and therefore none
  required porting.

## Related modules

- `lib/incus/**` was not touched in the audit range and remains byte-for-byte
  identical across all nine files and tests.
- `lib/systemd-user-manager/**` is absent in both repositories. It was removed
  by the documented native `systemd.user` migration and must not be resurrected.
- Pvl's three populated stacks still pin `backend = "compose"` while Abird
  defaults to Quadlet. This is a deliberate, documented host-policy divergence;
  see
  [Pvl Quadlet host migration blockers](../lib/pvl-quadlet-host-migration-blockers-2026-09.md).
- `scripts/**` has twenty common files, all byte-exact; the two Abird-only
  scripts are mail-operation tooling owned by Abird.

## Validation

- The configured `abird` remote was fetched and frozen at `857ac6eb` before
  comparison.
- Three independent read-only lanes verified: (1) the phase-one/phase-three
  commits, (2) the AI/PrismML/runtime commits, and (3) a full path/mode/blob
  parity audit.
- Each divergent common path was checked by blob hash and mode; no mode differs.
- The exact-set hash was recomputed directly from `git ls-tree`/`git rev-parse`
  output and matches the independent audit.
- No commit, push, deployment, service restart, image pull, database query,
  migration, or persistent live mutation was performed. Secret-key files were
  neither listed nor read.

## Conclusion

No shared implementation, test, package, or overlay export from
`28631f93..857ac6eb` still needs porting into Pvl. The twelve commits are either
byte-exact shared units already present, or Abird-only identity/product/host
surfaces with no Pvl consumer. The residual fourteen common-path differences are
the documented Pvl policy and repository-identity boundaries. Pvl `master` is in
shared convergence with Abird `857ac6eb`.

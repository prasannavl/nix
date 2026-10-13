---
id: 20261004T030817Z-product-evidence-io-validated
plan: 2026-w40-rust-fabric-implementation
actor: product-source-implementation
kind: source-validation
---

# Product semantic source preparation and evidence I/O repair validated

Source claim: `20261004T025806Z-product-evidence-io-claimed.md`. Independent
reviewer `01a104d4` identified the alias/ancestor-swap P2; this event records
the implementation owner's repair validation, **not** independent re-review or
native execution. MAIN will request the same critic's re-review.

## Durable source and repair

- `scripts/rust-g4-qualification/product_semantic.py`: parameterized
  binary/final/expected-spec API, inert import, original named-resource CLI
  protocol, exact version/JSON/resource/operation/status/exit expectations,
  bounded timeout/pipe logging, state/data absence observations including
  dangling links, atomic owned evidence publication.
- All manifest/raw stdout/stderr/per-case JSON/summary creation now uses the
  opened stage directory descriptor and `O_EXCL | O_NOFOLLOW`, mode 0600.
  Existing symlinks **and regular hardlinks** reject without truncation.
- CLI cwd/manifest/state/data paths use the inherited stage descriptor through
  `/proc/self/fd/FD`. Ancestor/stage inode bindings are checked before/after
  commands and around parent-descriptor no-replace publication. Evidence writes
  and cleanup never resolve the original absolute staging pathname.
- Cleanup enumerates a freshly opened `.` relative to the owned descriptor to
  avoid stale overlay directory streams, removes only owned-stage contents and
  its inode-bound entry under the opened parent, and refuses unsafe recursive
  traversal. Replacement links/directories are not cleaned. An owned stage moved
  out of that parent may remain empty rather than being chased outside.
- Specification input reads open components no-follow, require regular files,
  and bound reads to 1 MiB. No `.key` or secret paths are read.
- `test_product_semantic.py`: hermetic fakeRepo under repository tmp, all CLI
  subprocesses/signals mocked, source SHA/mode checks and alias/swap controls.
  No real product executable, Cargo, compiler, data or source copy is used.
- `product-acceptance.nix` and `product-acceptance-test.nix`: explicit
  construction from actual derivation handles, actual triple equality before
  serialization, store-context binary/spec/source inputs, opaque/mismatched
  identity negative controls. Pvl-only `product-eval.nix` imports its original
  constructor once and supplies identity expectations; acceptance is opt-in via
  `enableProductSemantic = true`, with default-off behavior unchanged.
- Narrow script README API/security documentation updated. MAIN-owned canonical
  docs, plan/work materializations and indexes were not edited.

## Validation

Durable report/logs/evaluator/source-hash snapshot:
`evidence/20261004T030817Z-product-source-acceptance/`.

- **31 product mock tests + 28 existing fixture tests PASS.** New controls cover
  symlinks and hardlinks for all ten post-CLI evidence filenames, tmp-parent,
  fakeRepo-ancestor and stage swaps, publication-time parent swap, and bounded
  regular/no-follow specification reads. Outside sentinel bytes and modes stay
  unchanged; owned stage cleanup and replacement preservation are asserted.
- **32 cached offline no-IFD Nix controls PASS:** 13 product integration
  controls, 16 host-neutral module controls, three actual binding guards. JSON
  uses `assertionsCount`. Original 11 constructor controls remain unchanged.
- Default evaluation has no acceptance target. Opt-in adds only the explicitly
  invoked target/bindings, not another selected product. `selectedTargetCount`
  remains 1. Product, original default and compiler identity triples exactly
  match the retained historical evaluation.
- Actual product final remains
  `/nix/store/9gdg03r03fgp5dl10j15lmdsa1kdrrii-abird-host-agent-0.1.0.drv`,
  output `out`, store path
  `/nix/store/g6p03pwkp65p6yzdy4lqnh453klvhfdg-abird-host-agent-0.1.0`.
- SHA/mode snapshot of **452 selected code/Cargo files** under `lib/flake`,
  `pkgs`, `scripts` is identical before/after validation. Snapshot hash:
  `30ce57dc09049361aa238bf2da8bc25cba36ee1747ba57737687eb6eedde3617`. This
  explicitly scoped snapshot is not a claim about the reviewer's separate
  648-file snapshot.
- Alejandra checks on the three Nix modules, Deno formatting/checks on changed
  Markdown, Python syntax, new-module/test 100-column and whitespace checks
  pass. Existing 190 staged paths remain unchanged; staged diff SHA-256 remains
  `18a7711aabf13969fbd374c37c4e31e0c248a8d4c98cad0697877953ba7ad8b5`.

Successful owned implementation scratch is promoted to the evidence directory;
no registry/private-cache dependency was added to the generic runner. Existing
native private-root cleanup belongs to MAIN and is not reopened here.

## Evidence limits and handoff

No native/Cargo/container/fetch/substitution/realization, staging, commit, root
registration/adoption, identity port, compiler/dependency/flags/default change
or producer/executor redesign occurred. All native grants remain CLOSED. The new
acceptance module is **not native-qualified** until a future separately admitted
actual run. Historical matching CLI evidence remains historical.
Descriptors/absence observations do not prove arbitrary data reads/effects or
exact producer/unit identity; producer remains `qualified = false`,
`decision = not_proven`, adoption off. Independent re-review is still pending.

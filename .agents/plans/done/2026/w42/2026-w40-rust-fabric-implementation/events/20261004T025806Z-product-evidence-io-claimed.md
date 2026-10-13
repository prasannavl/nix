---
id: 20261004T025806Z-product-evidence-io-claimed
plan: 2026-w40-rust-fabric-implementation
actor: product-source-implementation
kind: source-claim
---

# Product semantic evidence I/O repair claimed

Human delegated the remaining source-owned semantic runner/negative controls and
explicit acceptance module in the retained Pvl worktree. Initial implementation
started at 2026-10-04T02:41:15Z; this claim records the follow-up source-only
repair allocated after independent reviewer `01a104d4` found a concrete P2:
path-based evidence writes could follow a CLI-created symlink or hardlink and
truncate an outside file before semantic rejection. Absolute staging paths also
exposed evidence I/O to ancestor replacement.

Owned changes: `scripts/rust-g4-qualification/product_semantic.py`, its mocked
regressions, the narrow script README API section, and validation evidence/work
events. The already-created `product-acceptance.nix`, construction regressions
and opt-in Pvl `product-eval.nix` integration are revalidated, not redesigned.
All evidence operations must bind the opened owned stage; file creation must be
exclusive/no-follow, publication must use the opened parent, and cleanup must
not follow replacement paths. New alias/ancestor-swap controls must preserve
outside bytes/modes and original sources.

Native/Cargo/container/fetch grants remain CLOSED. No realization, staging,
commit, root registration/adoption, dependency/compiler/flags/default changes,
identity port, producer/executor work or nested agents are authorized. MAIN owns
canonical docs/plan/work indexes. Existing 190 staged paths are preserved;
observed staged diff SHA-256:
`18a7711aabf13969fbd374c37c4e31e0c248a8d4c98cad0697877953ba7ad8b5`.

The source acceptance target remains unexecuted/not native-qualified. Historical
native product evidence remains historical evidence of its matching CLI
protocol, not a realization or certificate for this new module.

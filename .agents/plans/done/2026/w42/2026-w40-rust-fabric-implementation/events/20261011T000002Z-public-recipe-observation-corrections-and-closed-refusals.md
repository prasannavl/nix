---
type: validation
project: rust-foundation
plan: 2026-w40-rust-fabric-implementation
coordinator: MAIN
state: public-metadata-refused-source-comparator-fix-required
---

# Three distinct public metadata scopes closed; no manager build

This corrects the attribution in233943 and later materialized views without
editing their frozen records. The first metadata-only expression selected
lock.nodes.nixpkgs instead of the actual root nixpkgs_2. Its OOM after3.625s
therefore did not observe the intended current package case. MAIN owns that
expression mistake. Receipt614 bytes SHA256
`b1c73f4573ce1a857f2b448d62684c10988c34f4f2584e21e148bc1bd6c24238` under
`.agents/runs/rust-foundation-qualification-public-inputs-20261011/`.

The separate corrected-root fetchTree expression was independently Source/argv
reviewed before one invocation. It refused exit1 after7.846s, not expired,
because the local Crane Git object627cb7161ed316b4c534a2f6c6cb7e5f95557c27 was
not found. A heap expansion warning also appeared; the final error is not OOM or
a consumer failure. No acquisition/repair followed. Receipt679 bytes SHA256
`f2be5a07c786f8ac9e40fa8ac17ffa62507e4b58ae4a190b80833dfcc97f1958` under
`.agents/runs/rust-foundation-current-root-recipes-20261011/`.

A separate expression used the original qualification README's documented
existing physical nixpkgs/Crane imports, with guards for the actual root-lock
hashes. It was independently reviewed in full before MAIN verified exact pins
and invoked it once. Review5970 bytes SHA256
`64b592e1720b530bfcdaad8c3e2d75cc2e64c218c105826dc167067291e43657` under
`.agents/runs/rust-foundation-cached-root-recipes-20261011/`. It stopped exit1
after15.982489s, not expired. Primary final error: attribute consumerContext
missing at expression39 in localNoParent; h does not export that API. A heap
warning preceded it. MAIN owns the comparator implementation error; this does
not establish a native recipe, Cargo reuse or cache/custody failure. Receipt686
bytes SHA256 `8a9701fdf29458e7ee2891f555aaa518c8f0b2fd09cc11b669e12fec6177af64`;
stderr1635 bytes SHA256
`c85b06cc91d1f7757e5faf626af4d615941d652f5a98b7d290f6d4da86fa42c4`.

Every unit had wall25/CPU15/AS512MiB/oneCPU/file16MiB, offline/noIFD metadata
only. Every unit is closed and fully charged; all exact Source, reviews and
outputs are retained. No limit increase, failed-unit retry/refund/deadline
renewal, fetch/cache repair, private root probe or native/build operation.

Next unblocked implementation unit: correct and test the complete constructor
comparison against actual exported helper APIs in a separate Source candidate,
independently review all final bytes and argv, then decide one finite
observation. No archived command or restored metadata is fresh custody/execution
approval. Current recipe identity remains missing; no build scope can be
admitted from these receipts. Initial manager PASS must precede warm follow-ups;
all remaining immutable/Abird/platform/cost gates are unchanged.

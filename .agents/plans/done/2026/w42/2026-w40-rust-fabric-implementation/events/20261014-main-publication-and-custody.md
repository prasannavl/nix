---
type: decision
plan: 2026-w40-rust-fabric-implementation
actor: human:prasannavl
recorded_at: 2026-10-14
---

# Main publication and lossless cleanup boundary

## Publication and current-source boundary — 2026-10-14

Human `prasannavl` explicitly authorized pushing both master branches and
removing Rust side worktrees only if no longer needed. Abird's three upstream
commits were integrated by normal merge `fdc23588`; both Rust and agentic
documentation and helper policies were retained. There was no force push or
history rewrite.

The new upstream AW dependency introduces `Cargo.lock.nix`. The generic
foundation closure/base/mirror paths reject that unsupported policy explicitly;
the original regular package route retains upstream's exact source replacement.
No lock normalization or policy-file omission is accepted to manufacture cache
parity. The previously completed six-case VM/mirror qualification retains its
actual Pvl `d82fa09b` and Abird `544e1881` pins; it does not certify this newer
Abird lock policy or every product. Extending the supported policy shape needs a
separately qualified source/vendor/mirror contract. Broad defaults remain off.

Cleanup audit found no unpreserved implementation commit patch: Pvl's side HEAD
is ancestral; Abird's one ancestry-only commit is patch-equivalent to main.
However Pvl R still has 955 dirty/untracked records and 164 ignored roots; Abird
A has 69 tracked modifications, 28 untracked roots and ignored tmp. Historical
evidence and source-inputs were intentionally not read or discarded. Both side
worktrees remain necessary for custody until those local overlays and ignored
artifacts are separately preserved. No unrelated worktree is removed.

The first Pvl push hook rejected two Markdown format issues. The historical
manager event's original bytes are retained in its `.md.raw` counterpart (SHA256
`8cb9479320bfe0a41d25d6fd943b633060f3bc6d50dd525805354836c8ca0d29`), and its
`.md` file is now a formatted rendering. The original R event is unchanged. All
other historical event bytes remain unchanged. Normal pre-push hooks are
required for publication; no validation bypass or insecure-package waiver.

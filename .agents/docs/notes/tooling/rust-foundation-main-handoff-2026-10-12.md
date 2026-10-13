# Rust foundation: integration closeout

Updated 2026-10-14.

Rust foundation is integrated into the local master branches of Pvl and Abird.
Current-input qualification passed all six manager cases in both repositories:
fresh baseline, cache hit, binary-cache export/delete/restore with builds
disabled, ordinary forced warm recompilation, changed warm and independent
changed fresh. Cache transport preserved exact NAR identity and compiled zero
crates. Both warm cases compiled only agent and manager: two workspace, zero
external crates. The changed-source probe and original installed version passed
in both variants. Independent byte determinism remains optional FAIL in both
runs.

Actual committed manager mirrors passed write/check and all four consumption
routes have equal package/build/base/vendor/tool/fleet/check identities. They
join the current VM recipes exactly. The original default manager recipes,
tools, checks and fleet inputs are identical before/after integration in both
repos; existing outputs passed installed version without another build.

Pvl Source validation passed 1,076 assertions and 146 Python tests plus syntax
and native-shell controls. Abird Source validation passed shared byte/mode/type
joins, 562 pure assertions, 90 pure toolchain checks, current policy/toolchain
18 each and actual 24-base/context controls. Twenty native constructor contexts
are supported; four contexts remain explicit declines: controller check-env
projection, two WASM adapters and parent-owned Tauri hooks/assets/strictDeps.
Cross/partial-WASM admission rejects. No 24-product execution, ARM runtime or
universal payback is claimed. The earlier 15.1% timing saving belongs to the
qualified candidate's selected-manager comparison, not these newer-input runs.

All new qualification VMs use 16 CPUs / 16 GiB. Normal systems keep regular
Cargo and their existing default-off policy. Patched Cargo and strict
independent byte determinism remain optional qualification routes. No production
defaults, compiler flags, source fingerprints or outputs were normalized or
switched. Releases continue to use fresh Nix builds.

## Current immutable results

- pvl: committed source `d82fa09bed7678484638a3de2cb3f84b5aed2c04`, runtime
  `/nix/store/ffia0nfcdpzigd3h2srpsrb2wf4rgxh3-vm-test-run-rust-foundation-pvl-main-integration-16cpu`.
- abird: committed source `544e18818a3456a8858a04db5ff54bd57183e3c2`, runtime
  `/nix/store/cjqj6ckhwla54xccz8v74az73ykj25j8-vm-test-run-rust-foundation-abird-main-integration-16cpu`.

## Custody and next work

The canonical plan is closed at
`.agents/plans/archive/2026/2026-w40-rust-fabric-implementation.md`. The done
capsule is `.agents/plans/done/2026/w42/2026-w40-rust-fabric-implementation`.
Pvl's done capsule retains the public historical event stream; Abird retains its
local coordination record and current integration events. Raw private execution
artifacts and unmerged historical staging remain in the original R/A custody
worktrees; no historical worker/read/archive unit was reopened. Those trees are
retained to avoid deleting unmerged local state. Active implementation and all
new work now belong in the two main worktrees.

Push to both main branches is authorized in the publication follow-up below.
Broad adoption remains separate. No compiler metadata investigation is selected.

## Regeneration

Use the done capsule's retained integration evidence and its REGENERATION.md.
Generate mirrors from a full committed main revision, never from dirty or
validation-only candidate snapshots. The generator rejects output beneath its
source repository; use the other repository's owned tmp directory or a sibling
source/output layout. Compare actual current-root overlay identities before
joining prior runtime evidence; newer Nixpkgs or product sources require a new
current-input validation. Earlier candidate proofs retain their actual pins.

## Retained evidence and repository boundary

Public joint evidence root:
`.agents/plans/done/2026/w42/2026-w40-rust-fabric-implementation/20261013T152913Z-integration-evidence`
(`/nix/store/m61fkqdik5b3j6dcncc4g6szzgv47rin-rust-foundation-main-integration-public-evidence`).
Its `integration/` contains current source provenance, immutable mirrors,
runtime logs and independent reviews; `REGENERATION.md` is the replay
entrypoint. `qualification-cutoff.md` retains the original main qualification
record at landing, including the bounded 24-member evaluation/cost/platform
results and their historical source pins. Raw event bytes are unchanged.

The original integration cutoff excluded the then-pending upstream work. The
publication follow-up below records its later normal integration.

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

## Historical event rendering — publication lint follow-up

The normal pre-push hook required headings, quoted-paragraph separators and
Markdown link syntax in 23 additional historical event documents. Original bytes
are retained verbatim next to every changed rendering as `.md.raw`; those
originals, rather than the formatted `.md` views, preserve the historical byte
pins. The original R custody tree was not edited. The earlier two-file
formatting cutoff is historical; no evidence or receipt was regenerated. The
append-only rendering validation event records each original SHA256.

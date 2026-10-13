# Rust foundation: completed integration

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

The canonical plan is closed at
`.agents/plans/archive/2026/2026-w40-rust-fabric-implementation.md`. The done
capsule is `.agents/plans/done/2026/w42/2026-w40-rust-fabric-implementation`.
Pvl's done capsule retains the public historical event stream; Abird retains its
local coordination record and current integration events. Raw private execution
artifacts and unmerged historical staging remain in the original R/A custody
worktrees; no historical worker/read/archive unit was reopened. Those trees are
retained to avoid deleting unmerged local state. Active implementation and all
new work now belong in the two main worktrees.

Publication/push and broad adoption remain separate. No additional qualification
build or compiler metadata investigation is selected for this integrated scope.

Current result event:
events/20261013T152913Z-main-integration-current-runtime-pass.md.

## Retained evidence and repository boundary

Public joint evidence root:
`.agents/plans/done/2026/w42/2026-w40-rust-fabric-implementation/20261013T152913Z-integration-evidence`
(`/nix/store/m61fkqdik5b3j6dcncc4g6szzgv47rin-rust-foundation-main-integration-public-evidence`).
Its `integration/` contains current source provenance, immutable mirrors,
runtime logs and independent reviews; `REGENERATION.md` is the replay
entrypoint. `qualification-cutoff.md` retains the original main qualification
record at landing, including the bounded 24-member evaluation/cost/platform
results and their historical source pins. Raw event bytes are unchanged.

Abird's three pending origin/master commits include separate product/dependency
work, beyond this validated Rust integration. They remain outside the local
landing; no upstream merge, push or unrelated qualification is claimed.

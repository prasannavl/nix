---
type: validation
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T04:23:24.974690+00:00
---

# Qualification-only Cargo fixes unchanged warm; changed warm/fresh differ

Actual patched matrix closed with all four build/package/version cases PASS:
baseline 273.20s; unchanged forced warm 101.76s; changed warm 89.20s;
independent changed fresh 232.01s. The exact 2-workspace/0-external
unchanged-warm frontier passed. Both guests checked absence of nine tested
outputs before compilation; boot 110.86s. Baseline versus required forced warm
NAR identities match.

The matrix nevertheless FAILED its final changed warm/fresh NAR equality
assertion: both member artifacts and final package hashes differ under identical
derivations/inputs. This is a newly reached failure, not the previously proved
binary dep-info ordering failure. Runtime semantic difference remains unknown.
No full qualification or blanket only-qualification limitation is claimed. The
normal saved partial JSON pins actual results:
tmp/nixos-patched-cargo-qualification-20261013/manager-partial-result.json,
20805 bytes, SHA256
152439c8d3622161044230535c61eceba16588b0b6e8585652380a75d58dbb3d. Failed outer
test outputs were discarded; normal build log retained the full structured
result. Code Source pins still match current qualification files.

Selected a fresh bounded diagnostic for this new failure. It warms only the
actual manager dependency base, builds identical changed source in warm/fresh
guests, captures normal parent closure NARs, copies both final packages/member
artifact archives and each actual parent archive, and publishes them as a
successful diagnostic collection, never as passing qualification. It skips the
already proved forced warm and unnecessary baseline member/package rebuild.
Sources: tmp/nixos-patched-cargo-changed-diagnostic-20261013/collect.nix and
collect.py; normal build-v2.log. Initial collection startup was cancelled during
boot before Cargo after detecting GNU readlink -f can resolve a nonexistent
leaf. The corrected collector first tests for the parent .prev symlink. No
historical private cache/receipt or closed archive-reader case is reopened.

Existing 300-second case/1800-second global framework limits remain. Optional
patched Cargo is isolated from regular system/default Cargo. No production
change, custom compiler/fingerprint rewrite, gate waiver or publication.

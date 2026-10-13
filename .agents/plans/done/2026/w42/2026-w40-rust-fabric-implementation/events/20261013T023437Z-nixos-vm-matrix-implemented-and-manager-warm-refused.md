---
type: validation
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T02:34:37.842819+00:00
---

# NixOS VM matrix implemented; manager warm output refused

Human instruction: "yes, set it all up quickly using nixos test framework".
Implemented stock-framework guest matrix and original manager adapter in R.

## NixOS VM implementation and current result

The human-authorized NixOS test framework is implemented in R under
`scripts/rust-fabric/qualification/`. Two disposable guests have independent
writable seeded store images, no host-store mount, no remote builders or
substituters, no guest network fetching and no IFD. Nix uses sandbox=true,
sandbox-build-dir=/build and sandbox-fallback=false. Original manager
Cargo/Crane recipes, compiler flags, full lock/vendor and compatibility guards
remain unchanged.

The final smoke passed baseline, forced unchanged warm, changed warm and
independent changed fresh, including exact guest derivation identities,
seed-output absence, installed behavior and NAR equality. The actual manager V4
baseline build/version passed; its forced unchanged warm rebuild failed Nix
output equality. Ordinary warm logs contain exactly two workspace compilations
(agent and manager) and zero external compilations, both under
/build/cargo-workspace-source. Fixed sandbox paths alone are insufficient for
artifact determinism in this case; the differing field/cause remains unproved.
Changed manager cases stopped at that first refusal and were not run.

Next work is a bounded artifact-determinism implementation fix preserving the
compatibility contract, followed by this existing matrix. Do not replay a spent
case, expand the VM harness, or reopen archive-reader work. CargoFresh remains
not_observed and full qualification, original cost, mirror, Abird/platform and
integration/adoption acceptance remain open. The 7-core/8-GiB guest environment
is separate from the original cost gate. M24 remains closed.

Reproduction, seed selection and retained evidence are documented in
`.agents/docs/notes/tooling/rust-foundation-nixos-vm-2026-10.md`. Current R
validation event:
`20261013T023437Z-nixos-vm-matrix-implemented-and-manager-warm-refused.md`.

Final smoke report:
/nix/store/4f9zhi6csjm05y4y997pkbk7rv2605as-vm-test-run-rust-foundation-vm-smoke/matrix-observations.json,
7849 bytes, SHA256
0c0c2b6778fe96300df2c2e3d58835a2afe728ad4c5f11507432a8285d6fcd0b. Actual manager
V4 outer build log in R tmp/nixos-vm-qualification-20261013/:
manager-v4-build.log, 247445 bytes, SHA256
2c375ff1100b81ae7f958311273b3263452a587bc83d75c34373a157bccbae2c. This normal
log records the closed first warm refusal; it does not retain a standalone
baseline NAR receipt. No later changed case ran, and no successful manager
qualification is claimed.

Promoted the actual seed-selector body to manager-seeds.nix, parameterized by
recipes rather than a temporary evaluation path. Exact selected path equality
against the executed V4 selector is checked separately; no native replay.
Historical reader and M24 evidence remain frozen. Failed setup logs are retained
while useful for this root cause. Source code remains in R; only informational
handoff/plan/note updates are synchronized to mains. No staging/commit/push or
production integration selected.

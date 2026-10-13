---
id: 20261002T141712Z-native-context-claims
at: 2026-10-02T14:17:12Z
actor: agent:rust-fabric-main
type: workstream.claimed
subject: milestone:bounded-native-context-and-packaging-projection
tags:
  - area:rust
  - skill:nix
  - collaboration:parallel
---

# Next phase: bounded native caller context

Human requested the next phase at the prior code-only boundary. Work remains in
the retained worktree; defaults, primary branches and runtime gates are
unchanged.

- Designer `agent:01a0fce8-7463-74c4-80f2-1c120b9387fa` completed the read-only
  projection contract. Add only `buildAttrs` to base/composition construction;
  compiler context is reconstructed, not accepted from recipe certificates.
- `agent:01a0fcf6-0d37-74c4-80f2-1c14b3cb5939` owns helper/factory stage
  routing, recursive context threading and native integration tests. Preserve
  original null/default and existing zero-context injected paths through
  explicit branches.
- Coordinator owns pure `rust-compile-context.nix` and its tests, registry/docs/
  events. The first 39 projection assertions pass. Local path environment values
  use interpolation to retain a store input/context, not bare `toString` paths.
- Admitted context is ordered declared native/build/check/lint inputs plus nine
  positive-list native discovery environment names. Profiles, flags, arbitrary
  hooks/stdenv callbacks, Cargo/home/target/tool controls and cross remain
  rejected.
- Promote conditional native inputs identically into producer/member/check
  stages. `postInstall`, metadata and final test toggles stay out of expanded
  cache stages. Final packaging must not publish artifacts or become a
  compiler-cache handle.
- Explicit zero-context compatibility branches remain literal; projection alone
  does not certify complete Cargo units or arbitrary setup-hook effects.
- Independent review follows delivery. No builds/capture/fetch/full-root
  evaluation, staging, commits, pushes or root adoption is authorized by this
  phase.

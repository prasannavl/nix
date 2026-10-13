---
id: 20261005T135700Z-original-m-adoption-forwarding-implemented
type: integration-and-validation
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-fabric-main
coordinator: agent:rust-fabric-main
source_owner: agent:01a10c42-532a-7761-baac-126c65caaa32
reviewer: agent:01a10c49-7ec5-7761-baac-126e83b75cbe
state: minimal-original-m-seam-implemented-worktree-only
tags:
  - area:rust
  - seam:externalPackagesFor
---

# Actual implementation: root adoption callback forwarded

MAIN verified original three-file hashes immediately before atomic replacement
(default first, then root) and integrated the independently reviewed minimal
four-line/two-production-file patch. `lib/flake/root.nix` now accepts optional
`externalPackagesFor ? _system: {}` and passes it to `default.nix`;
`default.nix` accepts the same optional parameter and passes it to existing
`packagesFn` in `withPkgs`. Existing packages.nix bytes unchanged. Every other
working-tree byte in the two files retained, including unknown user/index
ownership.

Four focused pure captured-call controls passed under oneCPU/2GiBAS/30s, offline
direct-module Nix/no IFD/no root flake. Boundary stubs prove inert empty
default, explicit empty equivalence, callback/system forwarding and unrelated
projection laziness; these are not actual root-flake/mirror/runtime parity.
Production Alejandra checks and targeted whitespace checks passed. Independent
review.md ScopedPASS explicitly read after agent transport aborted; checks.json
absent, not fabricated. Exact source hashes, baselines, evaluation and
integration receipts retained in the current phase.

Root remains repository-blind, default stack/helper context and package-owned
deps/flags/hooks/checks/wrappers unmodified. No new composition modes, toolchain
substitution, registry, default flip, root adoption, mirror publication or Abird
port. Existing external constructor contract can explicitly capture coherent
member helpers; caller/native equality remains unqualified. No stage/commit /
merge/push/index mutation. Most-specific revision-mirror note and canonical docs
index updated. Resource diagnostic source preparation remains an independent
short bounded lane; no native slot armed yet.

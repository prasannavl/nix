# Rust lockfile contract repair — 2026-10-14

## Cause

Abird fleet diagnostics `diag-8144cc44bf904d5d9027dad20b75fc0d` failed on corp's
ordinary `tg-parrot` package during Cargo setup. The repository's
`Cargo.lock.nix` policy removed the AW Git source line for vendoring, while the
source Cargo.lock retained it. Nixpkgs rejected the source/vendor comparison
before compilation. Upstream `be2a9490` introduced that divergence; language
extraction preserved it. Root and host evaluation did not execute this hook.

## Repair

One private Rust-platform adapter now installs the effective supplied lock in
the build tree after caller postPatch commands and before Cargo setup compares
it with the vendor lock. All four ordinary builder entrypoints use the adapter.
It accepts inline contents or an evaluator-visible lockFile path. It honors
cargoRoot and preserves caller file transport and patch commands. The checkout
lockfile, vendor definitions, hashes, compiler flags and Cargo remain unchanged.

A matching source lock preserves the original constructor attributes and
identities. Only a proven internal source transformation can use its original
path's matching-lock exemption; an opaque override installs explicit contents
without reading or realizing that source. Explicit cargoDeps or cargoVendorDir
owns vendoring and suppresses installation of an otherwise ignored cargoLock.
The shared adapter and checks are identical in Pvl and Abird. Abird's repository
policy remains separate from optional closure/base/mirror admission.

Service reconstruction remains unchanged. Direct replacement of its raw package
set with `_module.args.pkgs` recurses while the module's source factory
determines option declarations. Preserving host package context needs its own
module contract design; freezing a captured package or adding projection
scaffolding was not selected. Correct lock handling makes the existing ordinary
route work.

## Validation

- The real corp-selected tg-parrot package built successfully, including all
  eight package tests. Fixed derivation:
  `/nix/store/fkvipv9sxvw8ilfydfa8iv5r3m7ybpsr-tg-parrot-0.1.0.drv`.
- Corp's real zulip-parrot and zulip-robin source/vendor setup checks passed.
  These probes deliberately stop before Rust compilation; they are not complete
  product-build evidence.
- Both repositories passed the dependency-free real build regression for
  workspace-member and isolated-workspace constructors, plus exact lock and
  caller-patch output checks. Removing the installer reproduces the original
  source/vendor mismatch before compilation.
- Twenty-seven pure checks passed for lock and source overrides, vendor
  precedence, no-change identity, cargoRoot, caller hooks and no-IFD opaque
  sources. Eight existing Rust suites passed in both repositories.
- Shared changes passed formatting, syntax and static checks. No qualification
  VM, deployment, default-policy activation or new byte-determinism claim is
  part of this repair.

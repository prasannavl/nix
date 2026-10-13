---
type: decision
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T03:51:13.004060+00:00
---

# Human authorizes patched Cargo only for optional qualification

Human explicitly approved the pinned upstream Cargo PR16691 fix for
qualification until upstream incorporation, while regular systems keep regular
Cargo and qualification stays optional. This supersedes the pending decision and
narrowly qualifies the no-patched-Cargo contract. It does not authorize
production Cargo changes, compiler/fingerprint reimplementation, default
adoption, publication or historical native replay.

Implemented patched-cargo.nix plus the upstream patch (only diff filename
prefixes adapted to Nixpkgs' src/tools/cargo root). Optional
manager-patched-vm.nix snapshots that exact tooling and derives actual allowed
seeds. Normal manager-vm/manager-recipes default to qualificationToolingSrc=null
and unchanged regular identities. Explicit qualification operation tools and
Crane bindings carry the patched Cargo path; no global Nixpkgs overlay is
installed. Full-source manifests/lock/vendor/recipe guards remain unchanged.

Patched Cargo /nix/store/hh65jyhcss2xq4nasmflzhg2pw73kvri-cargo-1.95.0.drv built
from original Nixpkgs recipe with existing patches plus the exact upstream
change. The real cargo-order-check passed two independent binary-dep-info hash
comparisons and source-edit invalidation with original rustc. Its first test
attempt lacked a C linker in stdenvNoCC and failed; the corrected explicit
linker test passed without Cargo or rustc changes. Regular manager remains
/nix/store/97rg1y03xan751brq5mnwrm5gh9v0x4j-abird-host-manager-build-0.1.0.drv
and regular Cargo remains
/nix/store/05vdg0qyjpk27rf0ijylpz3x5hr0gp2r-cargo-1.95.0.drv.

New manager matrix uses the actual patched producer identity
/nix/store/2vzdmg6srx1k7bx2bccm329bp3lf5y2d-abird-host-manager-build-0.1.0.drv,
fresh independent guest stores, original no-fetch/no-IFD/ fixed sandbox
path/seed absence gates and normal forced --rebuild without --keep-failed.
Native testcase commands remain 300 seconds per case, stock 1800-second global
cleanup bound. Prerequisite tool build/boot costs are separate from original
performance gates. Current Source and identities live in owned
tmp/nixos-patched-cargo-qualification-20261013; each actual result must retain
its environment label and cannot certify unpatched cache byte equality.

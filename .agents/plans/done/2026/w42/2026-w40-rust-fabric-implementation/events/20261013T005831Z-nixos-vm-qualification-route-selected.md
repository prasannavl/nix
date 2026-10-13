---
type: decision
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T00:58:31.203402+00:00
---

# NixOS VM route selected for prospective qualification

The human proposed NixOS VMs as a clean alternative after the original M24
container refused Nix sandbox namespaces. Main selects a prospective NixOS VM
route under the existing validation preapproval. This supersedes further
container namespace troubleshooting as the next environment unit, not the closed
M24 record or any acceptance requirement. No VM/native grant is issued by this
decision and no VM was built or booted in this turn.

Read-only host inspection found /dev/kvm present, a character device, and
read/write accessible to the current user. That does not prove a VM boots or KVM
ioctls succeed. QEMU is not on the current PATH; use the pinned Nix package
closure. Existing repo lib/tests use pkgs.testers.runNixOSTest. The pinned
nixpkgs qemu-vm.nix supports virtualisation.useNixStoreImage and
mountHostNixStore. Its default 9p mode physically exposes host store paths even
when only selected paths are registered in the guest; this is unsuitable for
claiming an independent fresh build.

Use disposable guest-owned writable stores from an explicit seed/image and
mountHostNixStore=false. No host-wide store, private state or credentials share.
Exclude tested artifact outputs from the independent fresh seed while allowing
admitted toolchain/vendor/source inputs. VM source, kernel/OS, original Nix,
Cargo/rustc/Crane, recipes/features/flags and store seed must be pinned and
reviewed. Run ordinary Nix with sandbox=true and fallback=false directly in the
VM; adding Podman inside it would reintroduce the disputed boundary.

The first bounded execution unit proves VM boot, writable guest store and an
ordinary minimal sandboxed build before preparing the full manager matrix. Its
inputs/resource/deadline and cleanup scope must be explicit and fresh; no use of
M24's spent native300. Keep image preparation/boot costs visible and include
scope-required setup/verification/build/cleanup in each declared budget.
Original 1CPU/2GiB cost acceptance remains separate from the human14CPU/16GiB
override.

Use one baseline VM, a disposable copy of its actually qualified guest store for
unchanged forced warm then controlled changed warm cases, and an independently
seeded fresh VM for the exact changed source. Frozen warm cache custody and
input identities precede reuse. Independent disk/overlay state is mandatory; no
concurrently shared writable store. Network fetching/substituters/remote
builders and IFD remain disabled for qualification. Compare expected Nix/Cargo
rebuild frontiers, output/NAR hashes and installed behavior. Matching
derivations alone is insufficient. Fresh guest evidence and independent review
precede qualification; no historical receipt transplant, recipe change, default
switch, commit/push or production deployment is selected.

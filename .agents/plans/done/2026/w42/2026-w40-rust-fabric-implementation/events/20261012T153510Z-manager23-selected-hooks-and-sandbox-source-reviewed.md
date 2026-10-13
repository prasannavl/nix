---
type: review
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
reviewer: agent:m22_reviews_pipeline
timestamp: 2026-10-12T15:35:10Z
status: public-source-reviewed-native-feasibility-unproved
---

# Selected hook bodies reviewed; sandbox prospectus remains unselected

The independent reviewer completed a bounded public Source follow-up. Each of
the exact four selected hook leaves has a root-owned, read-only, single-link,
nofollow held/full-root/held/path-stat9 and complete body/hash review. All four
are byte-identical to the previously reviewed installed or cached bodies:

| Selected `nix-support/setup-hook` parent                                   | Bytes | SHA256                                                             |
| -------------------------------------------------------------------------- | ----: | ------------------------------------------------------------------ |
| `/nix/store/1l1q76xnsi8rf9pvs46g8b2qz1472mrg-cargoHelperFunctionsHook`     |   545 | `b2f612aa02e47f19fa40675cb4c8370fa571a8cc088a6a94ae41ad75a1b95626` |
| `/nix/store/ga6nzjl99k49i1cc7jn28fypnvvy0jci-configureCargoCommonVarsHook` |  2263 | `09c4673b837ab8388fc711e5850fa171f9147c149219e7a5a3f67c09a9b5453b` |
| `/nix/store/c92fqry9ajcblxra649z0sj3jkyk534g-inheritCargoArtifactsHook`    |  5571 | `612801110ccc84075abb6010b3df978de177607958ea330e62f2675fde1fa874` |
| `/nix/store/nmxc4sw7fpnif2767vq37gvd0wbf57y5-installCargoArtifactsHook`    |  4160 | `d54a63af5c70e81258c4b3a5316ecfb18bef6f65d45f7ff8df0defa7a0672af3` |

This closes the selected-leaf body-review limit prospectively. The immutable
152900 event remains correct at its earlier metadata-only cutoff. No changed
hook behavior or added remap hook was found. No private archive, Nix/SQL query,
runtime image configuration or native execution was involved.

The reviewer also read exact tagged Nix 2.34.8 primary sandbox Sources:

- [linux-derivation-builder.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/unix/build/linux-derivation-builder.cc):
  33,836 bytes, SHA256
  `358bf4288f86e9b0475734c89a288870ca734d012b5143589e36ce62e7b9c888`.
- [chroot-derivation-builder.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/unix/build/chroot-derivation-builder.cc):
  7,803 bytes, SHA256
  `449de15272e6a12c13fbcd2076454e6902af0ab4cd736c83c494a36b0c915441`.

The Source supports a user-namespace sandbox with an empty build-users group,
including one-ID mapping and setgroups denial. Parent UID1000/capabilities0
alone does not prove impossibility. Actual kernel, LSM and Podman seccomp
permission to clone/map/mount/pivot/chroot is unobserved. Native sandbox
feasibility remains unproved.

A possible later environment-only investigation would set sandbox=true,
sandbox-build-dir=/build and sandbox-fallback=false while retaining the original
identity, capability, NNP, seccomp, network, resource and recipe boundaries.
This prospectus is not a selected correction or native scope. No SYS_ADMIN,
unconfined seccomp, compiler flags or hook change is authorized by this review.
Any eventual stable-environment qualification needs a fresh actual manager
baseline followed by fresh forced warm acceptance; the prior nonsandbox baseline
cannot be rewritten into that proof.

The selected151623 semantic dependency-info unit remains Source/control/caller/
read-surface/independent-review pending at this cutoff. Its candidate component
comparison cannot prove the actual runtime root or binary cause. All original
qualification, cost, parity, mirror, platform and separate integration/adoption
gates remain open.

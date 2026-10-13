---
type: review
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
reviewer: agent:m22_reviews_pipeline
status: public-recipe-context-reviewed-runtime-parent-cwd-unproved
---

# Public recipe and build context reviewed

The independent reviewer completed a bounded read-only public Source audit after
the successful V6 comparison. This event records those Source findings, not an
archive reread, runtime configuration observation or production correction. No
private graph carriers or payload values were printed.

## Exact recipe graph and local Sources

The actual M21 and M23 Source graphs were authenticated by held full-stat9/hash
reads and are byte-identical: each 8,570,999 bytes, SHA256
`5e304ce967abf19b5eacc0432f11c44c9094fbb76f907c6617e25e9d4bb2e7da`, with 2,890
derivation rows. The exact selected `97rg` target uses `cargoWithProfile build`
with offline manager package selection and doInstall1. Its env has no
`RUSTFLAGS`, `CARGO_BUILD_RUSTFLAGS`, `doRemapPathPrefix`, `dontStrip`,
`TMPDIR`, `NIX_BUILD_TOP` or `sourceRoot`. That graph observation does not
establish the actual runtime environment or exclude hook/wrapper effects. The
same graph selects direct Cargo1.95.0 and the Rustc1.95.0 wrapper.

Authenticated public R Source pins:

| Source                               |  Bytes | SHA256                                                             |
| ------------------------------------ | -----: | ------------------------------------------------------------------ |
| `lib/flake/pkg-helper.nix`           | 107333 | `6d37454e35563e38dcfe345fdc2d556ee26e36769312752fbc8f0607554d51b7` |
| `lib/flake/rust-compile-context.nix` |   5242 | `1f642ddb755e8adb66b3cfcbba705c8ce5473a1b1f308b94e680009ca73eff31` |
| `lib/flake/member-bases.nix`         |   4442 | `c70d9180f0796dd44add36f8c14ac3f55dc06243322f2142e43bff341d27c876` |
| `flake.lock`                         |  18476 | `728e41fc4b2fa64d1ae7e45ff0f94d29414e37b297cc7bd64cc6100248874ab1` |
| Current M23 `worker.py`              |  31199 | `dc1d86527625259bf3c9f7d6672fe4c197e681ecdf8c752f35830fd4b99cb95c` |
| Current M23 `runner.py`              |  32764 | `1a64764bd416cf6b92e6027cdf99d743d109dce3f46adc8e7eeedbf967777626` |

The two current M23 Sources are in
`R/.agents/runs/rust-foundation-manager23-diag-20261012/`. Worker lines435/437
clear the environment, set TMPDIR=/tmp and explicitly select sandbox=false; they
specify neither build-dir nor state-dir. Public helper lines145-156 use the
cargo-workspace-source basename and stable `/build` virtual-path assumption.
This is a candidate context mismatch, not proof of the actual runtime parent,
working directory or cause. Actual image configuration was not admitted or
queried.

## Public Crane hooks

Exact installed standalone hook bodies were authenticated with nofollow held
full-stat9/hash reads:

| Source                                                                     | Bytes | SHA256                                                             |
| -------------------------------------------------------------------------- | ----: | ------------------------------------------------------------------ |
| `/nix/store/jwpzxjdmpa7by4c4v0plm60wz7kg9yah-installCargoArtifactsHook.sh` |  4160 | `d54a63af5c70e81258c4b3a5316ecfb18bef6f65d45f7ff8df0defa7a0672af3` |
| `/nix/store/zqiaj0r99r1lmbpw2lfr32xhv3080lg6-inheritCargoArtifactsHook.sh` |  5571 | `612801110ccc84075abb6010b3df978de177607958ea330e62f2675fde1fa874` |

Cached upstream files under
`/nix/store/rkz006xkgqrn2dav1274ggmqf00p9w46-source/lib/setupHooks/` were fully
read with held/root0/full-stat9 authentication:

| Source                            | Bytes | SHA256                                                             |
| --------------------------------- | ----: | ------------------------------------------------------------------ |
| `cargoHelperFunctionsHook.sh`     |   545 | `b2f612aa02e47f19fa40675cb4c8370fa571a8cc088a6a94ae41ad75a1b95626` |
| `configureCargoCommonVarsHook.sh` |  2263 | `09c4673b837ab8388fc711e5850fa171f9147c149219e7a5a3f67c09a9b5453b` |
| `remapPathPrefixHook.sh`          |  2926 | `ea9d189306d6395776565a0ea5a92c7a18498c5cdc076bb7e999dfe591e25c48` |
| `remapPathPrefixHook.nix`         |   156 | `d02687216c68be2cba847cfffcf4a6c6164c3bc1ccd0a9af9fcde06a0ba4ed95` |

The selected graph's four public hook directories are:

- `/nix/store/1l1q76xnsi8rf9pvs46g8b2qz1472mrg-cargoHelperFunctionsHook`;
- `/nix/store/ga6nzjl99k49i1cc7jn28fypnvvy0jci-configureCargoCommonVarsHook`;
- `/nix/store/c92fqry9ajcblxra649z0sj3jkyk534g-inheritCargoArtifactsHook`;
- `/nix/store/nmxc4sw7fpnif2767vq37gvd0wbf57y5-installCargoArtifactsHook`.

Their exact `nix-support/setup-hook` leaves were checked for metadata presence
only; the reviewer did not body-review those four leaves. Do not substitute
cached/standalone body review for that missing selected-leaf body proof. The
remap hook is not selected for the target. Common-vars defaults are release and
incremental=false. Compression normalizes mtime to epoch1 and uid/gid0, but mode
normalization only adds owner write. These Source mechanisms do not attribute
the actual eleven metadata differences: metadata also includes size.

## Exact primary upstream Sources

The reviewer read the complete tagged upstream primary Sources, with these full
body pins:

| Primary Source                                                                                                                      | Bytes | SHA256                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------- | ----: | ------------------------------------------------------------------ |
| [Nix2.34.8 derivation-builder.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/unix/build/derivation-builder.cc) | 77045 | `20e6b09df2b4f0b31b7bd4dd4a0f8041d955a7c66ef1852476bf82503cbcb25b` |
| [Nix2.34.8 file-system.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/file-system.cc)                           | 23800 | `d129033a49092a2e3f44949eab5aa42931119671025278c65f61299b363a4047` |
| [Nix2.34.8 local-store.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/local-store.cc)                          | 56967 | `ae5f2cb70f05b2301664c3fae2d56e211ee44211b6a405deb6a700bf92929088` |
| [Nix2.34.8 local-store.hh](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/include/nix/store/local-store.hh)        | 16173 | `3d97153513e29502ea63f1c850ed2b63815bbc910e7cf2ef96fe41abf9769361` |
| [Rust1.95.0 passes.rs](https://raw.githubusercontent.com/rust-lang/rust/1.95.0/compiler/rustc_interface/src/passes.rs)              | 54381 | `f933ca3be60593dd554252b323d8991a2cbe414d9f8557c20fac92d764e8ad3d` |

Nix builder lines270-282/702-710/1025-1035/1228-1230 and sandbox-choice
1943-1975 provide static build-directory context. `makeTempPath` lines571-578
uses a nix/PID/uint32-counter component. `getBuildDir` lines74-79 selects
global, then store configuration, then stateDir/builds. Those configurable
parents are not actual runtime observations; neither `/tmp` nor historical
nix-build naming is assumed. Rust dependency-info writer lines513-723 provide
distinct target, fake-phony, env-dep and checksum forms, with space escaping.
Complete supported grammar/coverage remains a diagnostic admission obligation,
not a shortcut to certifying unparsed equality.

No SQL/Nix query, native build, image-configuration read or archive reread was
performed for this audit. Actual runtime parent/CWD, specific differing metadata
fields and archive cause remain unproved. No compiler flag, recipe or hook
correction is selected. The frozen151623 diagnostic scope still requires fresh
complete Source/caller/read-surface/controls/peer review before its once-only
semantic execution. All original G1-G11 and separate integration/adoption gates
remain open. Previous failure/success/proof events are unchanged.

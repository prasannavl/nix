---
type: source-review
plan: 2026-w40-rust-fabric-implementation
actor: agent:packet_readiness
coordinator: MAIN
state: exact-source-streaming-route-reviewed-implementation-pending
---

# Exact original constructor public Source bodies use scalar streams

This independent Source review concerns the original public workspace and cached
nixpkgs/Crane Source-body criterion under the unchanged128MiB total read budget,
including repeats. It follows full raw-authority reconciliation in 035336 and
scoped daemon-body review033328. It does not establish an all-kernel,
all-compiled-object, all-global-database or all-virtual-mapping criterion.

MAIN reported a separately closed v2 constructor refusal PUBLIC128, with no
recipe result. Its coarse reservation receipt identifies neither an offending
file/syscall nor actual physical bytes read. Conservative reserved virtual
extents do not establish original qualification impossibility or authorize cap
increases. Preserve both closed constructor units and all predecessor bytes.

## Official Nix2.34.8 public Source acquisition chains

The reviewer consulted the exact official release Source, not a later Nix
implementation. Ordinary import evaluation reaches parseExprFromFile and reads
the resolved SourcePath before parsing:
[eval.cc2970-2975](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libexpr/eval.cc).
SourcePath readFile delegates to its accessor:
[source-path.cc16-19](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/source-path.cc).
The accessor's string overload uses a StringSink and its virtual sink reader:
[source-accessor.cc45-51](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/source-accessor.cc).

The physical Posix reader opens a no-follow FD, obtains its size and calls
drainFD with expectedSize; it does not map the Source body:
[posix-source-accessor.cc37-57](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/posix-source-accessor.cc).
drainFD iterates bounded64KiB buffers through read:
[file-descriptor.cc123-172](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/file-descriptor.cc).
The Linux implementation issues scalar ::read and scalar pread for offset reads:
[unix/file-descriptor.cc18-38](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/unix/file-descriptor.cc).
The monitor's permanent requested-byte admission already covers these calls,
including repeated, partial, failed and interrupted requests without refunds.

builtins.readFile and builtins.hashFile consume SourcePath readFile through the
same accessor chain:
[primops.cc1930-1956 and2142-2152](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libexpr/primops.cc).
Source snapshot copying uses fetchToStore's SourcePath and Store::addToStore:
[fetch-to-store.cc72-101](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libfetchers/fetch-to-store.cc)
and
[store-api.cc109-140](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/store-api.cc).
Flat serialization calls SourcePath readFile; NAR serialization calls its
dumpPath:
[file-content-address.cc60-69](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/file-content-address.cc).
SourceAccessor dumpPath streams each regular body through the same virtual
readFile, while the physical dump helper constructs a Posix accessor:
[archive.cc37-112](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/archive.cc).
Thus original source preservation, public source hashing and repeated NAR body
acquisition remain scalar-accounted. No cached text library is assigned zero
read cost.

For the exact UDS store selected by --store daemon, the previously reviewed UDS
overrides select LocalFSStore accessors and client-side Store::narFromPath:
[uds-remote-store.hh](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/include/nix/store/uds-remote-store.hh).
LocalStoreAccessor derives from PosixSourceAccessor and delegates readFile to
that stream reader; object accessors also construct PosixSourceAccessor:
[local-fs-store.cc39-104](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/local-fs-store.cc).
Daemon Source-body ingestion/optimisation remains separately conservatively
covered by permanent3x every scalar outbound request under033328's explicit
normal NoRepair/version/configuration limits. Generated derivation and global
DB/GC metadata are not silently claimed to be covered by that certificate.

## Limits and proposed scoped implementation

Nix has a DIFFERENT generic helper that can map files when its memory_map
argument is selected:
[file-system.cc252-272](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/file-system.cc).
It is not the reader used by the reviewed SourcePath/Posix acquisition chains
above. This event does not prove that every mmap is ELF or database metadata,
nor identify any mapping in the closed actual run. It establishes the stated
public Source streams for the exact original constructor route; compiled runtime
ELF virtual padding is not a public workspace/nixpkgs/Crane text body.

The proposed native correction is an optional strict source-streaming-route
mode, defaultOFF. Generic/default mode must continue permanently charging every
nonanonymous file-map requested page extent against the same aggregate cap. Only
the externally reviewed exact Nix2.34.8 executable/argv, physical original root
and cached source imports, no-plugin empty-held configuration, offline and noIFD
original constructors may select the scoped mode. In that mode VMA extent is
outside the stated Source-body reservation, because those Source bodies use the
scalar routes above; mapping counts must remain explicit. This is NOT a generic
mmap ingestion certificate or a permission for arbitrary targets.

Native evaluator code is disabled by default:
[eval-settings.hh80-95](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libexpr/include/nix/expr/eval-settings.hh).
Only enableNativeCode registers importNative/exec:
[primops.cc4942-4955](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libexpr/primops.cc).
The clean held configuration/no-plugin premise must preserve that setting and
refuse loader overrides. No custom evaluator plugins, native-code options,
alternate store/accessor/fetch route, Source fork or altered original recipe is
covered by this proof.

Retain scalar, daemon and conservative held-bootstrap reservations, original
SHA/workspace file16 guards, output file16/AS512MiB/CPU1/CPU15/wall25 caps,
unsupported acquisition refusal, owned cleanup and fresh final-byte joins. No
mutable FD inspection is used to exempt a mapping; its multithreaded TOCTOU
would not establish a safe route certificate. No additional tracing/executor or
transitive store census prerequisite is introduced. Full fresh C/control review
and exact final wrapper binding remain required before a new bounded unit.

This reviewer performed official public Source research and no Nix/child/build,
BODY/native qualification or private probe. This event issues no recipe result,
runtime grant, custody/reuse evidence or qualification PASS. User forward
authority remains distinct from execution evidence; no replay/refund of a closed
unit follows.

---
type: source-review
plan: 2026-w40-rust-fabric-implementation
actor: agent:raw_events
coordinator: MAIN
state: scoped-original-public-source-body-factor-reviewed-not-runtime-acceptance
---

# Original read authority and scoped daemon Source-body factor

The independent raw-events reviewer reconciled the original resource authority
and researched official Nix 2.34.8 Source. This event records Source analysis
only. It issues no monitor/runtime peer, reservation, current custody, recipe
result or qualification PASS. No Nix evaluation, native execution or protected
probe was performed by this reviewer.

## Exact original authority

Raw event234732 states: "Public SHA reads bounded16MiB/file and128MiB
aggregate"; protected/nonregular/read-ceiling records were stat-only and saved
DB snapshots were stat-only. Raw040722 states: "128MiB public read budget/16MiB
file limits" within its SOURCE envelope and prohibits protected cache/DB/WAL
operations. Raw003200 explicitly corrects the mistaken file-count
interpretation: "Original public Source read budget is128MiB, not128 files" and
"Actual Nix child library read accounting remains unproved". Later005800/011740
require cached libraries and repeated Source snapshots within the unchanged
total public READ cap.

These records establish public Source/SHA body accounting. They do not expressly
establish a new all-global-daemon-DB/GC-metadata or all-kernel-I/O criterion.
The guard itself accounts explicit bodies/rechecks while its directory census is
metadata-only. The reviewer's earlier global DB/GC counterexample answered a
broader proposed all-read interpretation; it cannot invalidate the original
Source-body gate or establish impossibility of compliant original qualification.
No library exclusion or original cap waiver follows from this reconciliation.
Human032039 authorizes implementing independently reviewed accounting and
batched original qualification; it is not runtime evidence.

## Scoped public Source-body bound

For the exact original normal NoRepair Nix 2.34.8 UDS constructor route,
permanently precharging three times EVERY scalar outbound requested byte is
conservative for these public input-body paths, in addition to child read/mmap
accounting. This requires complete scalar coverage, refusal of vector/other
unaccounted acquisition paths and charging before allowing each syscall.

- Recursive SHA256 source NAR: daemon ingestion reads the incoming stream;
  matching methods avoid an additional full NAR hash; automatic optimisation
  hashes each copied regular body at most once. NoRepair avoids hashing the
  existing `.links` counterpart. At most two times transmitted NAR bytes covers
  these body passes; framing increases the reservation.
- Public non-derivation Flat/Text SHA256: incoming text, installed-file NAR hash
  and optimisation require at most three body passes. Three times transmitted
  text bytes covers them.
- Every repeated transmission reserves again. Failed/partial scalar operations
  retain the requested-byte reservation; unused bytes are not refunded. Input
  bodies read before transmission are separately counted in the child. These are
  bounds on the stated paths, not claims about observed executions.

Official primary Source:
[remote-store.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/remote-store.cc)
(framed AddToStore),
[daemon.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/daemon.cc)
(AddToStore dispatch),
[local-store.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/local-store.cc)
(addToStoreFromDump), and
[optimise-store.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/optimise-store.cc)
(optimisePath).

The local daemon store's
[UDSRemoteStore overrides](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/include/nix/store/uds-remote-store.hh)
select LocalFSStore accessors and client-side Store::narFromPath. Ordinary
cached library/store-file access and client readDerivation therefore use direct
monitored child reads rather than a daemon body-return RPC. See
[local-fs-store.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/local-fs-store.cc)
and
[store-api.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/store-api.cc).

## Explicit certificate limits

Generated `.drv` metadata is different from the public non-derivation Flat/Text
case above. Daemon registration additionally parses the generated derivation;
checkInvariants can recursively read referenced derivation metadata, and a
SQLite retry can repeat registration. Thus three times outbound bytes is NOT a
certificate for all generated derivation metadata bodies. These paths serialize
inputSrcs references without dereferencing their public Source bodies. See
[derivations.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/derivations.cc),
local-store.cc addValidPath/registerValidPaths and
[sqlite.hh](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/include/nix/store/sqlite.hh).

Likewise global DB/GC metadata is not covered by this factor. Automatic GC may
read global temporary-root metadata and traverse store graph metadata; see
[gc.cc](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/gc.cc).
The original raw authority does not establish these categories as the public
Source/SHA criterion. This review does not silently relabel them as counted
zero, nor assert a broader daemon-read certificate. No outside-child regular
workspace/nixpkgs/Crane Source-body read was identified in the reviewed
registration/GC paths beyond the stated ingestion/optimisation passes.

MAIN supplied public configured-unit evidence that the nix-daemon service and
configured command resolve to the same exact Nix 2.34.8 package as the reviewed
client. This is attributed configuration evidence, not independent live-PID
executable authentication. This Source certificate remains scoped to that
original configured route; no daemon database/cache query was used to infer
current runtime state. Final accounting implementation, full-byte independent
review and fresh original bounded runtime admission remain separate gates.

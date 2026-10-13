---
id: 20261003T131400Z-member-invalidation-prerequisites-blocked
at: 2026-10-03T13:14:00Z
actor: agent:rust-fabric-main
type: blocker.recorded
subject: milestone:g4-native-member-invalidation-readiness
tags:
  - area:rust
  - authority:metadata-only
  - blocker:writer-cache
  - gate:new-native-and-fetch-budget
---

# Complete pruned graph assessed; native phase correctly stopped

Preflight owner `01a101e1-139f-74c4-80f2-1dd39f8fb24d` produced complete
metadata/ classification reports before an unexplained UI abort. MAIN recovered
outputs, read collector/classifier and rechecked all six missing outputs, 67
valid cached paths and 76 unchanged fixture file hashes. No incomplete readiness
presented as success. No build/fetch/Cargo/container/store bootstrap/index
operations occurred.

Exactly one actual-overlay x86 target, four member variants:
`/nix/store/2ff25pmnm97pq0vk18qdw102mgdj8v8q-rust-g4-member-invalidation-acceptance.drv`.
Thirty constructor controls pass. Recursive derivation metadata1513; exact
requested output-pair pruning visits103 (all103 unique derivations),52 valid
frontiers, 51 pending outputs. All13 pending input-source paths cached, zero
missing inputSrc; 2 omitted FOD output paths resolved with read-only nix-store
output queries. Selected cargo/rustc-wrapper/clippy/rustfmt1.95 roots cached. No
compiler/provider builds required at this point-in-time gate; cached validity is
not payload/whole- store attestation.

Pending51: **45 fixture outputs** (27 pure source/manifest/lock,17
base/member/final compilations,1 acceptance) plus **6 external/tool
prerequisites**:

- Crane writer drv `jpq1nxnrppr71vz7n1wf02gm6svrn9mv-crane-utils-0.0.1.drv`,
  output `lrp16ghr1dajq6wbnbb9vpkgpr2bq68s-crane-utils-0.0.1`.
- Its vendor support `ha7napxg3vb8yykvx7bn957bfc3h3lvd-cargo-vendor-dir`.
- Its unpacked crate support
  `pzpa7gwkvwr4shaprhx7fi2zbcabghmq-toml-1.1.3+spec-1.1.0` and
  `2xnrdk66jfjnp7kgjzcixm30a1diy5yl-toml_parser-1.1.2+spec-1.1.0`.
- Locked source drv
  `wbzzlpx1z6ywzmm4hw6v5336dd2s20dw-crate-toml-1.1.3+spec-1.1.0.tar.gz.drv`, URL
  `https://static.crates.io/crates/toml/1.1.3+spec-1.1.0/download`, flat SHA256
  `53c96ecdfa941c8fc4fcaed14f99ada8ebed502eef533015095a07e3301d4c3c`.
- Locked source drv
  `5mynpnx1w37czdmfmd9fvajzgjpzpn8l-crate-toml_parser-1.1.2+spec-1.1.0.tar.gz.drv`,
  URL `https://static.crates.io/crates/toml_parser/1.1.2+spec-1.1.0/download`,
  flat SHA256
  `a2abe9b86193656635d2411dc43050282ca48aa31c2451210f4202550afb7526`.

Exact pending paths/IDs and dependency chains retained in static evidence
`evidence/20261003T131400Z-invalidation-readiness/` (blockers, evaluation,
source hashes, compact summary). Classification names are metadata reporting
only, not source ownership, build authority, capability inference or producer
qualification.

The earlier writer output was private and cleaned, not host-published. Offline
fixture cannot proceed from current host cache. No silent source reacquisition
or prerequisite rebuild. Native edited behavior/freshness/reuse still
unobserved; producer remains `qualified=false / not_proven`.

## Approval proposal (not authority)

Request exactly the two locked downloads and four writer/support prerequisites,
then exactly memberInvalidation offline, **300 seconds aggregate native wall
time including prerequisite/fixture builds and retries**, one job/core,2GiB/no
swap, PID256. Same externally capped private-local rootless backend,
UID1000/cap-zero workers, no host daemon/remote builders/substituters/privileged
escape. Abort on new external miss, containment failure, budget exhaustion or
out-of-scope change. Network permitted only for the two locked prerequisite
sources; fixture network-none. No
compiler/provider/flags/profile/platform/legacy route or adoption expansion.
Propose retaining private writer cache only through the remaining G4
qualification series to avoid re-fetching each gate, with eventual owned
closeout cleanup; human must approve this retention exception to default
successful scratch cleanup.

Current owned `tmp/g4-invalidation-readiness/` fixture/evaluator/metadata
diagnostics retained while useful for approved continuation; no native cache
yet. Unrelated helper-consolidation/mirror log untouched. Existing190 staged
paths preserved; HEAD/Pvl `5ae0baf0`, Abird `1f4057ee`; no
integration/publication/default flips.

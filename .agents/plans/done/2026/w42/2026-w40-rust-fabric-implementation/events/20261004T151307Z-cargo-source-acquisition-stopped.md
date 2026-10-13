---
id: 20261004T151307Z-cargo-source-acquisition-stopped
type: validation-snapshot
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-fabric-main
observed_at: 2026-10-04T15:13:07Z
state: blocked-offline-source-inspection-approval
coordinator: agent:rust-fabric-main
reviewer: agent:01a10754-3f1f-7761-baac-114399028b96
tags:
  - area:rust
  - work:producer-source
  - validation:acquisition-stopped
  - scope:acquisition-only
---

# Sole transfer verified; Cargo inspection stopped

The human's "next phase" accepted the concrete one-transfer acquisition-only
proposal recorded in `20261004T135816Z-cargo-source-acquisition-approved.md`.
The sole real attempt is now over; no retry, guard relaxation, new transfer,
compiler/Cargo/Nix realization, patch intake/application, native qualification,
integration/publication or adoption is authorized. All prior native grants
remain closed and exact producer remains `qualified=false / not_proven`.

## Observed outcome

- Fixed release URL transferred516130239bytes (492.220MiB), below512MiB cap.
- Complete raw SHA verified before gzip/tar reader construction:
  `ea9b82a83e46967537c3569ce9d6fa16811c043a96e651376c349e70241ca515`, matching
  pinned `sha256-6puCqD5GlnU3w1ac6db6FoEcBDqW5lE3bDSecCQcpRU=`.
- Metadata inspection rejected a sensitive-looking component after9814physical
  entries/6225408decoded bytes. Exact rejected path was not retained: do not
  guess its component or whether it lies outside Cargo.
- Zero selected Cargo entries/bytes, zero materialized file bytes, empty owned
  output directory only. No Cargo graph/API/effect source review occurred.
- Outer invocation120.937804402s, exit1; worker reaped, helper bytes unchanged,
  external private group18697absent. Launch-subtree maxRSS31080KiB, user/system
  CPU2.218041/2.745904s. These are acquisition measurements, not build
  feasibility.
- Allocation300s conservatively fully charged and closed; no reusable unused
  authority. The source-allocation book is not the proposed build-fabric ledger.

## Preparation, review and evidence

Independent reviewer `01a10754-3f1f-7761-baac-114399028b96` found/followed
repairs for HTTP framing, independent literal root binding, startup/death
deadline, PID-reuse cleanup and final-report/inventory admission. Independent
tests by `01a10767-a273-7761-baac-114d7d09d75e` found five additional
directory/empty-file validator gaps, repaired and re-reviewed. Final
helper/supervisor scoped PASS; required external GNU timeout/prlimit,
parent-death interlock and post-wrapper private-group absence check were
actually used. No general native/builder containment claim is admitted.

MAIN independently reran59mocked helper and23synthetic supervisor controls:
exit0/0.257s and exit0/0.051s respectively. Source identity is intentionally
fake in supervisor fixtures; these results are never Cargo producer/native
evidence.

Evidence: `evidence/20261004T135816Z-cargo-source-acquisition/`, including
baseline, review, independent test logs, source allocation, worker
stdout/stderr, supervisor result and whole-command receipt. Frozen
helpers/review/test snapshots, historical and repaired synthetic supervisor
fixtures and copied failed reports were promoted atomically under
`helper-artifacts/` with a333-record byte/mode manifest. An initial promotion
stopped on the synthetic marker TXT; owned partial copies were verified and
completed without altering any acquisition guard or repeating
acquisition/inspection. Only the owned helper staging/successful synthetic
scratch was removed.

## Current blocker and retained failed state

The helper's generic sensitive-component policy is applied globally before Cargo
selection; the verified upstream archive encountered that conservative policy.
The precise rejected name remains unknown. This does not attest local
credentials or allow blind extraction. See indexed task note
`rust-cargo-source-acquisition-2026-10.md` and updated exact-producer contract.

Failed owned `tmp/rust-cargo-source-20261004T135816Z/` remains for human
direction: mode0400verified archive, initial/final diagnostics and empty
`cargo/`. No source store import or realization occurred. Ask whether to retain
it and accept a separately reviewed, newly bounded offline Cargo-only
reinspection with zero new network transfers. Preserve existing
byte/count/AS/time/selected-secret/link/ duplicate boundaries; any
metadata-policy change needs focused negative controls. No earlier grant or
unused wall allocation is reopened by that request.

Unknown staging ownership, existing constructors/defaults/wrappers/dependencies/
isolation and G4 fallback remain protected. Both retained worktrees and active
P2 queue stay live. Documentation/index/materialized-state updates record the
failure honestly; full source/index preservation and final docs validation are
recorded separately at closeout.

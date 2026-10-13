---
id: 20261003T160303Z-sourceguard-claimed
at: 2026-10-03T16:03:03Z
actor: agent:rust-fabric-sourceguard
type: workstream.claimed
subject: guard:synthetic-descriptor-extensions
tags:
  - area:rust
  - role:assigned-sourceguard
  - authority:code-only
---

# Assigned synthetic descriptor guard

Ownership: `scripts/rust-unit-spike/spike.py::descriptor`, relevant new cases in
`tests/test_spike.py`, and the harness README synthetic section. MAIN retains
canonical docs/index/plan/materialized work view; the G4 orchestrator retains
its own harness and sole native lane.

Baseline: all 56 spike/fixture tests pass. Descriptor currently drops unknown
unit and exact-wrapper attributes before hashing. Implement a narrow top-level
allowlist of existing exact fields and documented opaque unit/demand/freshness
labels; reject non-object units and unsupported wrapper attributes without
inference. Preserve explicit exact status/value, profile dictionaries, hash
normalization, build-time script references and source/role scope. Proc-macro
edge representation remains unsupported, not silently approximated.

Only Python synthetic/mock tests, short self-bounded dummy process tests,
targeted Markdown formatting and whitespace checks. No Cargo/native builds,
fetches, containers, source-key edits, staging or commits. Exact producer
remains `not_proven`; descriptor remains synthetic-only and unqualified.

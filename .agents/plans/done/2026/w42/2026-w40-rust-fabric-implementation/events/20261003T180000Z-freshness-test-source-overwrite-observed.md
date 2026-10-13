---
id: 20261003T180000Z-freshness-test-source-overwrite-observed
at: 2026-10-03T18:00:00Z
actor: agent:rust-fabric-main
type: blocker.recorded
subject: sourcegate:g4-freshness
routing_tags:
  - area:rust
  - severity:p2
  - sourcegate:hold
---

# Historical event: freshness test source overwrite observed

MAIN observed new freshness sources overwritten at17:52UTC by apparent test
fingerprint stubs: `freshness.nix`12bytes `moduleSha256`, `freshness.py`13bytes,
`freshness-eval.nix`15bytes. Controller/contained remain18851/8833bytes. Root
cause not yet verified: likely non-hermetic source-gate mock derives production
harness paths from a temporary ROOT with wrong parent depth. No historical files
touched observed; this concerns new task-owned freshness files. Do not assume
exact cause until source owner verifies. SourceGateHOLD prevents native
execution.

MAIN immediately steered owner to stop native, restore owned implementations
from its source history/backups, isolate tests under a correctly nested fake
repository, and verify all production source byte hashes before/after tests. No
launching stub/unreviewed artifacts, no unrelated user edits restoration. Native
ledger stillOPEN0/300; source failure is not actual Cargo evidence. MAIN
allocation does not bypass independent PASS or containment. Owner continues
autonomous repair; no new human routine approval requested.

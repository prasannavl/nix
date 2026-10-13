# 20261003T173620Z — G4 handoff review validation

Validation result: **honest gate failure recorded; handoff bookkeeping valid**.

Evidence:

- Raw invariants:
  `.orchestrator/g4-freshness-20261003T154900Z/evidence/closeout-raw-invariants.txt`
- Final report:
  `.orchestrator/g4-freshness-20261003T154900Z/evidence/finalverifier-report.md`
- Typed handoff:
  `.orchestrator/g4-freshness-20261003T154900Z/evidence/MAIN-ALLOCATION-HANDOFF.json`

Validated invariants:

- Fresh ledger hash
  `ce5a9c88975b71867a980c5f51c65b3689e5c7b82c985d59c1a91e1eb32649e5`,
  OPEN300/spent0/attempts[].
- Old ledger hashes preserved:
  `242c34fc71774f95aa08af2bbe8694bcc0e21ecbd7a5e92a4efa6ecf591421e5`,
  `6abf232facfaf64e22c403890261982e36af1cf1db3e2c6e57d6f976d78fb900`.
- Original fixture/source files rehashed: 76/76 match, errors0.
- Staged baseline: HEAD `5ae0baf0a7abdac0a5260ae8bfda004fdb01eadd`; cached
  staged path count190; index digests recorded.

Gate failure retained:

- No actual Cargo freshness/effects/locked-runtime attestation proven.
- No native runtime/container/resource proof.
- No exact producer/DAG/cost certificate.
- Static 56 tests + eval/formats and old budget mock/fixture snapshots are
  non-native only.

Ownership caveat retained: `34a44669` released no new files; harness released
per closeout input; old `669` may still own original
controller/contained/test-budget, so no full source-file idle/release claim.
Protect old paths; MAIN may use new product paths and private cache under MAIN
allocation.

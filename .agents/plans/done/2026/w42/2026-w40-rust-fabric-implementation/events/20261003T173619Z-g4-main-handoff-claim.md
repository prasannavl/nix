# 20261003T173619Z — G4 MAIN handoff claim

Claim: **G4_RELEASED_TO_MAIN**, actual G4 qualification **BLOCKED**.

Typed handoff artifact:

- `.orchestrator/g4-freshness-20261003T154900Z/evidence/MAIN-ALLOCATION-HANDOFF.json`

Budget transferred by authority artifact, without ledger mutation:

- Source ledger:
  `tmp/g4-native-invalidation-20261003T133000Z/aggregate-budget-20261003T154900Z.json`
- Hash: `ce5a9c88975b71867a980c5f51c65b3689e5c7b82c985d59c1a91e1eb32649e5`
- State: OPEN, limit300, spent0, attempts[]
- Remaining handed to MAIN: **300s**
- No reservation/refund/native action occurred.

Reason ledger not closed on disk: existing controller exposes only `init-grant`,
`admission`, `freshness`; no documented non-native close/transfer API. Ledger
retained OPEN; typed artifact is authority handoff.

Authority: G4 native authority revoked from source-only agents; MAIN owns unused
300s. MAIN may create product ledger `<= min(300,180)` referencing this source
ledger/hash, with no per-target reset and no old-ledger consumption.

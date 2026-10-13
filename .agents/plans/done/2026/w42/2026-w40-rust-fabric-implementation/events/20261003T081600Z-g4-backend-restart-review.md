---
id: 20261003T081600Z-g4-backend-restart-review
at: 2026-10-03T08:16:00Z
actor: agent:rust-fabric-main
type: review.completed
subject: backend:ordinary-worker-private-store-restart
tags:
  - area:rust
  - evidence:source-and-metadata
  - gate:native-pending
---

Independent reviewer `01a100cb-3880-74c4-80f2-1d5dd5edce0a` rechecked the
previously reported conditional restart P2. Confirms owner-first physical
private-tree traversal handles 0700 directories, restores directory
modes/UID1000, propagates errors explicitly and does not walk cached lower
entries. Existing fresh-container 0700/0600 byte/owner/mode tests cover that
failure. No other scoped P1/P2. Read-only recheck, no edits/execution/native
retries.

This closes the metadata/backend repair review, not native G4 acceptance. MAIN
remains paused for renewed bounded offline pilot approval. Source/lock hashes,
resource ceilings, unchanged production copy semantics and private cache
retention are recorded in `20261003T081500Z-g4-worker-identity-corrected.md`.

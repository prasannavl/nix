---
type: decision
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T03:22:01.941132+00:00
---

# Upstream ordering remedy identified; compatibility choice pending

The human asked how to proceed. Read-only upstream research identified Cargo
PR16691, proposed commit 074980c2670522e3bde8acb9a25b40510f78626c. Live primary
GitHub API reports open/unmerged. Its small change uses BTreeMap for dep-info
path records, matching the directly proved record-order defect.

Recommendation for strict raw cache reproducibility: a narrow human-selected
exception to no-patched-Cargo for that exact upstream fix, opt-in pinned
backport and fresh minimal/manager VM qualification. Changed Cargo identity
requires new compatible producer bases. Alternative for unmodified Cargo is an
explicit semantic-metadata qualification exception, with raw Nix rebuild failure
acknowledged. No contract exception, patch, build, gate waiver, publication or
adoption is selected by this event. Proposed route and primary references are
documented in the synchronized VM note and indexes.

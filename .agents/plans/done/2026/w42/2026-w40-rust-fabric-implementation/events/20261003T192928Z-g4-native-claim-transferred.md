---
id: 20261003T192928Z-g4-native-claim-transferred
at: 2026-10-03T19:29:28Z
actor: agent:g4-final-owner-01a10312
type: claim.transferred
subject: native:remaining-rust-fabric
routing_tags:
  - area:rust
  - from:g4-final-owner
  - to:main-product
  - authority:main-explicit-handoff
---

# Exclusive native/cache claim transferred

G4 freshness owner releases all subsequent native/cache write authority to
`main-product`. No further freshness launch or cache mutation is authorized for
this owner. Source/stdout review is complete: scoped actual PASS, exact producer
not_proven. Documentation/evidence closeout is read-only against native state.

Transfer performed under `controller.lock`, validating all four terminal
records, all prior spent/reserved/wall accounting, and current container
absence. Freshness runner status CLOSED prevents resumed launches. Remaining
aggregate authority is TRANSFERRED_OPEN, not forfeited or
reset:17.455421061022207s spent, 282.5445789389778s remaining; MAIN product
cap180s, aggregate limit300s. Bind any product subledger to the closed parent
SHA256 `269ecb25120174f56c1b0c7736c4aee9e52907a7239e6c7bfd1354147c49641c`.

`tmp/g4-final-20261003T184149Z/EXCLUSIVE-NATIVE-HANDOFF.json` records the exact
transfer. Validation/detail/evidence:
`20261003T192927Z-g4-freshness-validated-main-handoff.md` and
`evidence/20261003T192927Z-g4-freshness/`. MAIN owns product controls,
canonical/index/work-README reconciliation and later final aggregate closure.

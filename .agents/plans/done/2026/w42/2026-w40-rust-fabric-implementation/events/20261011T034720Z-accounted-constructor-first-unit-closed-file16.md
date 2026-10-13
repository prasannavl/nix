---
type: validation
plan: 2026-w40-rust-fabric-implementation
actor: MAIN
coordinator: MAIN
state: actual-constructor-unit-closed-refused-not-qualified
---

# First accounted constructor unit closed with FILE16

MAIN executed the exact reviewed event034719 unit once, with the external
25-second deadline and unchanged Source caps. The wrapper exited1 and the
monitor exited124. The saved receipt reports REFUSED, expired=false,
wall0.40410970407538116s, public explicit/known/reserved90741244 bytes,
monitor85164761 bytes against its128637452-byte remainder, bootstrap11659785,
continued665, mappings177, monitor metadata16384, outbound factor3,
childReaped=true, childExit=-1, and reason FILE16. The complete unit is CLOSED
and fully charged25 seconds; no retry, rearm or refund.

Saved ordinary public outputs under
`.agents/runs/rust-foundation-accounted-constructor-source-20261011/outputs/`
contain the1630-byte wrapper receipt and303-byte monitor receipt. Recipe stdout
and stderr are empty. Source/repository/bootstrap/output endpoint rechecks
completed before receipt publication. No recipes, BODY, native manager or new
private probe were accepted or executed by this unit. runtimeGrantIssued=false.

FILE16 is the monitor's coarse request-size refusal. It identifies neither the
syscall nor file, and no actual offender, actor or cause is inferred.
Independent Source reconciliation finds that imposing16MiB on page-rounded mmap
virtual extent is an additional restriction: virtual extent does not establish
Source body size. A fresh separately reviewed candidate may remove that
request-level restriction while retaining full permanent global128MiB
reservation of every file mapping, original Source/SHA file guards and OS file
output caps. Old Source, executable, receipts and records remain unchanged. This
correction is neither a Source-library exemption nor an original cap increase.

Current original qualification remains incomplete. Comparable current recipes,
genuine final packet/custody/proof, manager PASS before warm, full
reuse/locality/ inheritance, immutable parity and Abird/platform/cost gates
remain outstanding.

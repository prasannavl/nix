---
type: validation
plan: 2026-w40-rust-fabric-implementation
actor: MAIN
coordinator: MAIN
state: fifth-constructor-unit-closed-refused
---

# Fifth constructor unit closed with generic unsupported refusal

MAIN executed the exact reviewed wrapper once after scope042526, under external
KILL25 and the unchanged original caps. Actual receipt: REFUSED, native exit124,
wrapper exit1, expiredfalse, wall0.12365044304169714s. Total public reservations
17329069; native11744161 of128629073; bootstrap11659785; calls1271; mappings302;
metadataCalls0; monitor metadata8192. Owned child reaped; childExit-1. Recipe
stdout and stderr are empty. Runtime grantfalse. CLOSED/full25; no retry,
refund, rearm, private probe, BODY/native or manager/warm execution.

The monitor still reports UNSUPPORTED. The newly covered policy families did not
identify this refusal. Complete Source inspection finds other denial branches
without assigned family labels, so this observation does not prove a specific
syscall, request, actor, path, payload or cause. In particular it does not
identify the historical private ctimeNs failure cause. Similar counters across
units are not causal attribution.

Next finite Source unit completes coarse labels for the remaining denial
branches without changing admission or enforcement. It receives full Source and
control review before a synthetic component batch; any later actual constructor
is a fresh separately finite reviewed unit. No blind allowance or diagnostic
trace is authorized by this refusal. Original recipe/custody/proof, manager
before warm, immutable/Abird/platform/cost gates remain incomplete.

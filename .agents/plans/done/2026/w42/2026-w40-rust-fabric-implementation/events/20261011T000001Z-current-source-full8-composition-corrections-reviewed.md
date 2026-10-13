---
type: review
project: rust-foundation
plan: 2026-w40-rust-fabric-implementation
coordinator: MAIN
authors:
  - agent:/root/packet_boundary
  - agent:/root/history_inventory
reviewer: agent:/root/cleanup_port
state: corrected-code18-full8-support-source-accepted-unissued
---

# Corrected Code18 and complete Full8/support Source accepted

Independent complete final-byte review accepts the current unissued Code18 and
twelve Full8/support programs. MAIN read the complete report and freshly
verified all39 Source and19 program payload rows, sizes/hashes and reported
program modes. Report
`.agents/runs/rust-foundation-qualification-20261011-programs-review/review.json`:
19911 bytes, SHA256
`e9d4bd47dd34f9eaeedc87c18f626e74dff8f86ddab70c5e5befc73887841458`,
ACCEPT_SOURCE_ONLY, zero P1/P2/blockers. Source inventory5808 bytes SHA256
`e7f4a9034472725e21b5709f65fc0e08f7f46a5a0de68089732d6b70608d769c`; program
inventory3553 bytes SHA256
`76413e0b4906b918d1d57736a9ebea311395f939b8967dcfb18f9402792bc1f0`.

Actual composition exposed four defects beyond the earlier separately accepted
Code18 bytes: pre-BODY static helper binding incorrectly required runtime
manifest/dynamic inputs; reconciliation and seed loops shadowed digest/pin
validators; observer referenced the retired FREEZE global. The fixes separate
static Source joins from mandatory current_manifest_inputs runtime admission,
rename the shadowing locals and consume the already authenticated descriptor
freeze. helper_request, custody_paths and validate_main_custody still require
every actual runtime input. No missing-file bypass, synthetic dynamic receipt or
weakened final stat9/ownership predicate was introduced.

Author and independent guarded normal/O tests passed20 Code18 methods and26
program methods each, including actual composed pre-BODY static paths, all37
missing/forged runtime joins,24 whole program namespaces and10 direct
operational gates. Zero effects or armed mains. Limits
wall25/CPU15/AS512MiB/oneCPU/file16MiB. These are RAM Source/schema controls,
not genuine issued execution peers.

Code18 totals230396 bytes; programs167994 bytes. Source index45 and custody57
remain closed sets; runtime48, original tool/owner inventory and all22 named
safety obligations remain. Original recipes/full vendor/hooks/wrappers, BODY4/
Full8/support4 order, seven-field assembler review and flags, exact held-FD
bootstrap, finite full charging/no renewal and cleanup contracts are retained.
All programs are within32768 bytes, but observer32061 and inherited31904 leave
limited issuance headroom. Any literal substitution requires renewed complete
final-byte review and original cap checks, not a larger cap.

Original transport remains26633 bytes SHA256
`a1f2043068148c6ca5f14f1017a78ce705f9ccf0d53eaaa84108ae2c722eb305`; two
same-held-directory-FD reads remain within native300 with unchanged final stat9.
Earlier ctime actor/root/backend/magnitude/cause remain unknown. Previous
Source/reviews and frozen events remain byte-exact; this review supersedes only
current byte acceptance, not their recorded historical scope.

Genuine matching-grant helper/workspace/program/integration peers, SourceCap/
index/template/launcher, current Source7/Git/reconciliation/eight-anchor and
runtime/tool/cache custody, actual proof/clock/boot/FD and scope remain
unissued. No manager/warm build, private probe, immutable operation or Git
mutation occurred. Both Git index hashes freshly match the preceding MAIN
snapshot.

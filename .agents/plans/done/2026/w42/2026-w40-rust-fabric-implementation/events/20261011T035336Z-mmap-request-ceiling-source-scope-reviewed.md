---
type: source-review
plan: 2026-w40-rust-fabric-implementation
actor: agent:packet_readiness
coordinator: MAIN
state: mmap-only-correction-reviewed-not-executed
---

# Original file limits and conservative mmap request accounting

The independent reviewer completely reread raw234732,040722,003200,005800 and
011740 before interpreting the original resource boundary. Raw234732 states
"Public SHA reads bounded16MiB/file and128MiB aggregate" for the public handoff
inventory, with protected/nonregular/read-ceiling entries stat-only. Raw040722
retains "128MiB public read budget/16MiB file limits" in the original SOURCE
envelope. Raw003200 corrects the count misunderstanding: "Original public Source
read budget is128MiB, not128 files"; byte/file/partition caps stay unchanged.
Raw005800 and011740 explicitly include transitive cached libraries and repeated
snapshots in the unchanged total public READ budget.

None of these records establishes a16MiB virtual mapping or syscall-request
ceiling. A file mapping's page-rounded virtual extent can exceed its physical
body, including ELF virtual padding. Applying FILE16 to that extent is an
additional conservative restriction, not a proof of the original public SHA file
limit. Conversely a scalar request below16MiB never proves its backing file is
below16MiB, since repeated smaller reads are possible.

The smallest legitimate correction is mmap-only: remove its request-level FILE16
refusal while retaining permanent reservation of the complete4096-byte
page-rounded requested extent against the unchanged128MiB aggregate BEFORE
continuation. Preserve the original pinned SHA/public workspace body guards,
their16MiB file limits and output RLIMIT_FSIZE16MiB. Preserve HUGETLB/remap and
unknown-ingress refusal, scalar accounting, all repeated/failed reservations,
bootstrap accounting and original constructor/toolchain/vendor/flags.

Do not replace this correction with an unrequested transitive store census or
new executor/tracing prerequisite. Mutable target FD inspection cannot safely
justify a reservation exemption under multithreaded CONTINUE. No library
exemption, aggregate/file/output cap increase or original criterion waiver is
approved. Meaningful corrected synthetic controls and independent final-byte
review remain required before a separately recorded fresh bounded Source unit.

MAIN reported the preceding actual constructor unit closed REFUSED/FILE16 with
genuine childReaped=true and no recipe result. The coarse record does not
identify its offending file, syscall, actor or cause; this Source correction
does not invent that observation. Preserve its receipt, closed accounting and
all earlier bytes. This reviewer executed no Nix, child, build or private probe.
This review issues no metadata result, native/runtime grant or qualification
PASS. Existing human forward authority covers preparation; no per-run user
approval or replay/refund of the closed predecessor follows.

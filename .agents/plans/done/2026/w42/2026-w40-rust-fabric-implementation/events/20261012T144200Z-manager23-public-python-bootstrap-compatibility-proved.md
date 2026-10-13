---
type: validation
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
status: public-bootstrap-compatibility-blockers-proved-successor-unissued
---

# Public Python bootstrap compatibility blockers established

A distinct bounded public Python probe executed once, exit 0/empty stderr; the
independent reviewer authenticated its actual Source and result. Probe Source:
947 bytes, SHA256
`25eac6816ef0272a1a797cff108e73fc777b4309ea37a86bd67f1fbf7927d470`. Aggregate
stdout: 289 bytes, SHA256
`8a76c424434de72da6b15359eeebda5a9ea936ae340a07010d82cedffa36ad91`. The flags
`isolated`, `ignore_environment`, `no_site` and `no_user_site` were all 1. Its
only Python environment key was `PYTHONNOUSERSITE`; the original comparator
controller's environment-deny predicate evaluated true despite those exact
isolation flags. This establishes a deterministic prelaunch compatibility
blocker for that public bootstrap route.

Static analysis of the exact public wrapper ELF, 16,528 bytes, SHA256
`293ad1da9a2053a656cd3e9abfedc31667c82fa092deb993dba86abb064fd18f`, establishes
its main call graph: `putenv(PYTHONNOUSERSITE)` then `execv` of the exact
original underlying `9r02` Python target. The unchanged mode0 monitor permits
only the initial exec. Thus a wrapped monitor child would face a second-exec
blocker after the environment check. This static evidence concerns the exact
public executable, without artifact or private-root probes.

These findings establish compatibility defects and the next executable-launch
blocker. They do not trace the exact first stage of the recorded V3
`CLOSED_ARCHIVE_MONITOR_REFUSAL`, exclude earlier failures, establish accepted
artifact reads/comparison, or explain the native archive mismatch. The generic
V3 aggregate refusal contains no stage trace. Its Source25 is still spent, and
the native failure and 143200 comparator-refusal events remain unchanged.

Next is exact public underlying-ELF authentication plus isolation and standard
library context authentication, then a fresh controller Source patch retaining
the original Q `LD_`/`GLIBC_` filter, checking all four isolation flags,
selecting the original wrapper target directly for the monitor child, and
reporting a fixed opaque stage enum. Agent `m22_review` authors that candidate;
Main and an independent reviewer must completely read its Source/caller and
current pins before any new finite case. No successor is issued here.

The monitor, finite caps, exact private two-root Stage A selection, full
ownership/stat9/parent/link gates and bounded streaming Stage B remain intact.
No artifact Source-ingestion shortcut, library exemption, monitor relaxation,
private probe, spent-reader replay, retry or refund follows. Actual archive
ordering/timestamp/compression/payload cause and all original G1-G11 acceptance
remain unproved. M21 PASS, M22/M23 failed native cases and their finite
accounting remain unchanged; integration/adoption authority is separate.

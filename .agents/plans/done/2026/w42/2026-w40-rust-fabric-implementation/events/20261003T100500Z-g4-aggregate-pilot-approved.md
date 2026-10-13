---
id: 20261003T100500Z-g4-aggregate-pilot-approved
at: 2026-10-03T10:05:00Z
actor: agent:rust-fabric-main
type: claim.started
subject: milestone:g4-aggregate-offline-qualification-pilot
tags:
  - area:rust
  - authority:bounded-retries
  - scope:x86_64-linux
---

# Human approves driving the pilot to completion within aggregate native limits

MAIN asked: offline retries of the same two targets, total five-minute native
budget, one job/core, 2 GiB. Human: "let's go, continue all the to finishway".
Interpretation: finish this qualification pilot autonomously within those
limits, not broaden to root/host/Abird/provider/platform builds or
publication/adoption.

MAIN coordinates/executions. Use ordinary UID1000/capabilities-zero worker
backend, read-only cgroup, private local store and exact cached source/tool
context. Network-none/no pulls/substituters/remote builders. Aggregate native
wall time measured across attempts; per-container lifetime bounded by remaining
time with termination reserve. Hard CPU/memory/no-swap/PID limits unchanged.
Stop on exhausted budget or an out-of-scope blocker; do not silently widen
source/compiler contracts. Task-local code/backend repairs and same-target
retries allowed inside this pilot.

Retain real logs, source hashes, selected archive/semantic outputs and
no-freshness assurance boundaries. No Cargo-unit instrumentation/producer
qualification, extra routes/tests/variants, flags/profiles/default flips, host
config, commits/index or master integration. Existing 190 staged paths
preserved, HEAD `5ae0baf0`. Successful owned scratch may be cleaned after
durable consolidation; keep failed state while useful for diagnosing a remaining
blocker.

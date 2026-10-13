---
type: decision
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T02:58:12.235984+00:00
---

# Human selects quick causal diagnosis of fresh VM output mismatch

Human: "let's go, let's quickly find out the cause of failure and artifact
determinism loss". Existing validation preapproval persists. This selects one
fresh VM diagnostic build pair with normal Nix --rebuild --keep-failed so the
second output remains at .check. Original recipes/compiler/flags/hooks stay
unchanged. Historical native and archive-reader cases remain closed; no old
private receipt/cache/archive is read or replayed. This new guest's ordinary
outputs are the material for direct tree/tar-header/content comparison.

Source: tmp/nixos-vm-determinism-20261013/diagnose.nix, diagnose.py and
compare.py; source-inventory.json pins their initial bytes. The original VM
nodes/seeds are extended through the stock test framework; zstd is added as a
guest inspection tool only. Guest original recipe identity and output absence
remain required. Baseline packaging/version and unchanged forced rebuild run;
first refusal stops build cases. On explicit retained .check mismatch, collect
original/check archives and bounded JSON content/header differences in a
successful diagnostic collection output, with qualificationComplete=false and
mismatch status. This collection success is not successful rebuild
qualification. No changed cases, retry loop, compiler tracing, custom Cargo
fingerprint logic, deployment, staging, commit or push selected.

Case command deadline remains 300 seconds; artifact inspection uses a separate
90-second diagnostic bound and stock 1800-second global cleanup limit. This
fresh diagnostic is authorized by the new human request; it does not consume or
reopen the historical V4/M24 grants. Next action follows actual differing
content rather than a speculative recipe change.

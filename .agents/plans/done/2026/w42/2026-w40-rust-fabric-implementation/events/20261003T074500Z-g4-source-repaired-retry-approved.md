---
id: 20261003T074500Z-g4-source-repaired-retry-approved
at: 2026-10-03T07:45:00Z
actor: agent:rust-fabric-main
type: claim.started
subject: milestone:g4-source-repaired-native-retry
tags:
  - area:rust
  - authority:bounded-native-retry
  - scope:x86_64-linux
---

# Human approves one source-repaired fixture retry

Proposal: another offline one-core/job, 2 GiB, five-minute fixture attempt after
read-only root-manifest repair. Human response: "go".

MAIN owns execution and closeout. Same two archive/semantic acceptance targets,
no new tests/variants/platforms/fetches/providers/host
config/commits/publication. Retain private writer cache from separately approved
prerequisite step; refresh helper snapshot/target graph and selective private
metadata registration, validate complete pruned cache and external containment,
then run once. Abort on unavailable prerequisites/resource limits/runtime
failure; no silent retry or limit relaxation.

Private rootless local-store backend continues with read-only host-store lower,
owned writable upper/private DB, network-none, read-only root/cgroup, CHOWN
only, no-new-privileges, no host daemon/socket/remote builders/substituters. 2
GiB/no swap, one CPU, PID bound 256, container lifetime below five minutes.
Standard real logs and selected archive/semantic outputs only; no Cargo-unit
instrumentation capture.

Existing 190 staged paths preserved; HEAD `5ae0baf0`, masters unchanged.
Repaired opt-in producer identities are intentional; defaults/null remain
unchanged. Original fixture source/manifest/full-lock/expected bytes must remain
hash-identical. Producer stays `qualified = false`, `not_proven` until separate
fidelity evidence.

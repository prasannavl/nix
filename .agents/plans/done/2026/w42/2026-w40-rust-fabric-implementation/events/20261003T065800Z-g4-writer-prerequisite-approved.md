---
id: 20261003T065800Z-g4-writer-prerequisite-approved
at: 2026-10-03T06:58:00Z
actor: agent:rust-fabric-main
type: claim.started
subject: milestone:g4-writer-prerequisite
supersedes: blocker:20261003T063200Z-g4-native-prerequisite-blocked
tags:
  - area:rust
  - authority:bounded-tool-prerequisite
  - scope:x86_64-linux
---

# Separate locked writer source/tool step approved

MAIN explicitly asked to fetch locked Crane writer dependencies and build that
prerequisite with one job/core, 2 GiB and a five-minute limit, then retry the
fixture under its separate existing offline limits. Human response: "go on".

Scope: exact `crane-utils-0.0.1` derivation
`/nix/store/jpq1nxnrppr71vz7n1wf02gm6svrn9mv-crane-utils-0.0.1.drv`. Pruned
cache preflight finds six pending tool/support derivations, with two missing
fixed-output feeds on `static.crates.io`: toml `1.1.3+spec-1.1.0` and
toml_parser `1.1.2+spec-1.1.0`. Their declared SHA-256 hashes are authoritative.
No unrelated compiler/provider/dependency upgrade, substituter cache filling or
tool inventory.

MAIN owns execution. Metadata collector lane
`01a10083-5031-74c4-80f2-1d2d467ef87d` aborted after writing scoped temporary
collector; MAIN recovered/validated it without widening authority. Selective
host metadata export covers 1,997 existing valid paths (about 1 MiB), not
source/archive payload or whole-store copying. Private DB load and
cache-validity checks succeeded; no host load-db/build daemon fallback. All
temporary code/state under existing owned repo tmp directory.

Bounded rootless cached-image backend: read-only root, host store as immutable
lower/per-run writable overlay, private `/nix/var` DB, no host daemon socket,
local Nix store, network allowed only for this locked-source step. Cached inputs
retain exact store paths. Sandbox disabled only inside this isolated container;
Nix-managed cgroups disabled so all local builders remain in the externally
capped container cgroup. No remote builders/substituters. Runtime
CPU/memory/swap/PID assertions precede each operation. Container timer is less
than five minutes.

Overlay root mirrors unmapped host store ownership, so all-dropped capabilities
initially denied writes. Container-private CHOWN alone permits ownership of its
private overlay root; host lower owner/mode and contents remain unchanged. No
sudo/no-new-privileges bypass, privileged container, SYS_ADMIN capability or
shared daemon/service change. Private store bootstrap plus Nix version
succeeded.

Tool success does not itself validate G4 reuse. Fixture run remains separate,
network-none and one-job/core/2 GiB/five-minute. On tool
failure/time/memory/cache failure stop, preserve diagnostics and report; no
retry or limit relaxation. Existing 190 staged paths preserved, no
commit/history/publication/adoption.

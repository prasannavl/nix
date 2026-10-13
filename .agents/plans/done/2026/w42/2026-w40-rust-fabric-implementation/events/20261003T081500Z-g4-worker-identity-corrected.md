---
id: 20261003T081500Z-g4-worker-identity-corrected
at: 2026-10-03T08:15:00Z
actor: agent:rust-fabric-main
type: claim.blocked
subject: milestone:g4-source-repaired-native-retry
tags:
  - area:rust
  - finding:backend-worker-identity
  - evidence:metadata-probes
  - gate:native-retry-pending
---

# Second attempt stops before Rust; ordinary-worker backend now verified

Human-approved retry (`20261003T074500Z-g4-source-repaired-retry-approved.md`)
refreshed helper snapshot/target graph and selective private cache registration.
Complete private-store pruned cache check passed (27 fixture/support nodes).
Same network-none, one-job/core, 2 GiB/no swap/PID bound/read-only cgroup
backend.

Native command stopped in **0.38 seconds**, controller wall under one second,
before Rust or acceptance, on
`cp -a ... preserving permissions: Operation not
permitted` in original
full-source copy. Repaired projected-root dummy source nodes built successfully;
the prior manifest fix remains correct.

## Distinct backend defect, not a new production source bug

UID 0 plus CHOWN but without FOWNER is not an ordinary Nix build user. GNU
`cp -a` as UID 0 successfully preserves unmapped source ownership (65534), then
cannot chmod the newly differently owned files. Ordinary unprivileged cp cannot
preserve foreign ownership, keeps the destination owned by itself, and preserves
modes normally. No production cp semantics, source guard or compiler/writer
change is needed; never add worker DAC_OVERRIDE/FOWNER to hide this mismatch.

Temporary backend now uses a namespaced bootstrap with only CHOWN/SETUID/SETGID
capabilities to normalize **physical private upper/private DB entries only**,
then clears groups, sets UID/GID 1000 and verifies
real/effective/saved/filesystem UIDs 1000 plus effective/permitted/inherited
capabilities all zero, no-new-privileges and read-only cgroup. Nix CLI and every
local builder run after that drop. No host account/config/daemon change; minimal
passwd/group files are container-only binds. Host lower remains immutable and is
never recursively normalized/copied.

Executed ordinary-user probe: exact failed fixture source owner 65534; `cp -a`
succeeds as UID 1000/capabilities zero, copied manifest owner 1000/mode 0444.
Private writer cache validity and full same-scope preflight pass (25 pending
nodes). Source/manifest/lock/expected 19-file hashes remain unchanged. No native
rerun after backend correction; no fetches/archives/CPP/Rust compilation or
extra targets.

## Restart review and repair

Read-only reviewer `01a100cb-3880-74c4-80f2-1d5dd5edce0a` found conditional P2:
`os.walk` as bootstrap UID0 could silently skip UID1000-owned mode0700
directories on future restarts. Replaced with explicit private physical-tree
traversal: lstat without symlink following, temporarily own only private
directories for owner traversal, restore original mode, normalize owner to1000;
traversal errors raise. No DAC_OVERRIDE/FOWNER, no broad lower-store traversal
or link-target mutation.

Two fresh-container metadata controls seed a UID1000 0700 directory/0600 file,
then verify restart traversal, exact bytes/owners/modes, and remove only that
owned probe. Both pass. Strict UID/capability/cache/containment checks pass
afterward. This is backend/file-copy evidence, not Cargo/artifact-reuse
qualification.

## State/gate

No live native lanes/containers. Native archive/parity still incomplete; exact
producer remains `qualified = false`, `not_proven`. No silent retries or relaxed
limits. Private diagnostics/writer cache retained under
`tmp/g4-native-20261003T061200Z/` for another approved offline attempt. Existing
190 staged paths, HEAD/Pvl `5ae0baf0`, Abird `1f4057ee` unchanged; no
stage/commit/ publication/adoption/host-store output writes. Durable
note/index/plan/work view updated. Another same-scope retry requires human
approval; consider a cumulative five-minute native-attempt budget to avoid
reauthorizing subsecond backend failures.

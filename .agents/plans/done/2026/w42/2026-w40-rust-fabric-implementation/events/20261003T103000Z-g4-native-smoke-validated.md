---
id: 20261003T103000Z-g4-native-smoke-validated
at: 2026-10-03T10:30:00Z
actor: agent:rust-fabric-main
type: validation.completed
subject: milestone:g4-native-archive-semantic-smoke
tags:
  - area:rust
  - evidence:actual-native-smoke
  - scope:x86_64-linux
  - qualification:producer-not-proven
---

# Bounded native smoke pilot complete

Human approved driving the same two targets through bounded offline retries, one
job/core, 2 GiB, **300-second aggregate native budget**. MAIN execution attempt
1 succeeded in **26.268174 seconds** (Nix command 25.991677s), no retries/new
fetches. No unused budget spent on variants, extra checks/platforms or adoption.

Actual outputs (private local store, not host-published):

- `archiveChain` drv `dy3npvlbhi007r8f821xcnxzcxxiqqg6`, output
  `/nix/store/40xhlp144q6i35l0gv93yz5dipgvr7sw-rust-g4-archive-chain-acceptance`.
- `semantic` drv `vlc87qymk3gp8g6hqrbfa8lm76nfhjhs`, output
  `/nix/store/a1qlsc9dxdpjh0cnjmfy1li90abk8sz9-rust-g4-semantic-acceptance`.

Ordinary UID/GID1000, all worker effective/permitted/inherited capabilities
zero, no-new-privileges, read-only cgroup, CPU quota1, memory2147483648/no swap,
PID256, private namespace/store/DB, no daemon/socket/remote
builders/substituters, cached image/no pull, network-none, container deadline
within remaining budget. No shared service/host account/system-config/default
changes. Source context/tool versions unchanged by backend identity correction;
opt-in source command repair retained.

## Actual observed evidence

- Seven genuine source-closure bases and real member layer pass bounded
  tar-name/ previous-link inspection. Depths: leaf/peer1,
  branch/build-helper/macro/dev-helper2, app3, member-layer4. Raw
  fingerprint/build-output name counts retained in TSV.
- **17 real archive decompressions** in Crane logs, including selected-parent
  and member-layer restoration. All **five** selected child/parent link and
  extraction paths match actual constructor handles. App selects branch then
  leaf; final member consumer restores chain and real member-layer archive. No
  sentinel, producer override, fabricated logs, archive-format change or
  payload/fingerprint read by acceptance inspector.
- Baseline/member/legacy all match exact fixture-owned **74 bytes**:
  `source=leaf-v1;target=normal;build=input-v1:build+macro;macro=build+macro`
  plus LF. Each route also passes its one genuine target/dev-versus-host feature
  test.
- All **19** original source/manifest/full-lock/expected file hashes unchanged.
- Known final `target`, `target.tar.zst`, dangling `.prev` paths absent in all
  three package outputs. Expanded final-output guard phase not logged; absence
  is not guard-phase/arbitrary-hook effect attestation.
- Complete default/null final/member-layer/check identity triples compared
  before JSON serialization: unchanged in all four cached bare/overlay x86/ARM
  contexts. This avoids treating an `outPath`-coerced JSON set as a three-field
  observation.

Read-only actual-evidence reviewer `01a1013f-e12e-74c4-80f2-1d87e27b9e06` found
no scoped P1/P2, confirmed actual decompression/semantic/feature tests and
narrow limits. No execution/edits by reviewer.

## Durable evidence and boundaries

Static work-capsule `evidence/20261003T100500Z-g4-pilot/` retains full real
native log, archive TSV, common stdout, actual
source/project/parent/vendor/stdenv/output observations, original file hashes,
default/null identity Boolean controls and budget/result/log-hash summary.
Evidence only, not routing registries, artifact admission/certificates or
portable compiled capsules. Private output paths cease availability when owned
cache is cleaned; no host store publication implied.

Printed Cargo commands prove release/offline, **not --locked**; pristine hash
preservation does not certify unmodified copied build-tree lock or resolved
units. Cargo prints1.95.0; constructor/strip logs select rustc-1.95.0 store
path. Not full sysroot/native/platform attestation. Member final build
reports0.00s after archive restoration; do not infer quantified reuse savings or
exact Cargo freshness from that text. No exact unit
descriptors/features/roles/frequencies/build effects ledger. Std-only fixture
does not qualify external-crate reuse, edited/native invalidation/rollback,
representative native/platform/cost or root/Abird adoption.
`producer.qualified = false`, `decision = not_proven` stays unchanged.

## Closeout

Indexed qualification/explicit-base notes and docs index, canonical active plan,
materialized work view updated. Formatting/whitespace checks pass. Successful
owned private cache/code snapshots/evaluators/reports cleaned after durable
consolidation; unrelated `tmp/helper-consolidation` and existing
`tmp/rust-mirror-current-tests.log` preserved. Cleanup normalizes only physical
owned upper/work/DB metadata through CHOWN-only private container, then host
owner removes owned run tree. No lower-store traversal/chown; host store
owner/group/mode remains 0/30000/1775. No live owned containers; cached images
untouched. Initial failures are recorded through events, notes and persistent
source-mode regression rather than leaving execution clutter.

Existing 190 staged paths preserved; this task performs no
stage/commit/push/merge. HEAD/Pvl master `5ae0baf0`, Abird master `1f4057ee`, no
publication/adoption/deploy. Plan remains active/queued; this smoke milestone
closes, not full Rust fabric work. Next separately approved work:
invalidation/rollback/freshness/representative native acceptance, or another
code-only contract slice. No further autonomous native runs from the remaining
budget after successful target completion.

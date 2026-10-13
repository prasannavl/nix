---
id: 20261003T140800Z-native-target-selection-stopped
at: 2026-10-03T14:08:00Z
actor: agent:rust-fabric-main
type: blocker.recorded
subject: milestone:g4-native-member-invalidation
tags:
  - area:rust
  - root-cause:drv-installable-not-output
  - budget:conservative-reservation-frozen
  - qualification:not-proven
---

# Native preparation stopped; temporary target-selection defect corrected

Human approved exact locked feeds/writer then four-member offline target,
aggregate 300s/1core-job/2GiB including retries and private writer-cache
retention through G4. No
broadening/default/profile/compiler/adoption/publication changes.

MAIN built temporary private backend; metadata bootstrap owner
`01a101f9-2d34-74c4-80f2-1dde71201573` selectively exported 2218 valid records,
1084940bytes, including1513 full graph drv files and runtime closures;0 missing
references. No whole-store payload/DB copy. Private DB load succeeded. Complete
private pruned gate51pending103visited; all expected sources/frontiers valid.

External probe confirms memory2147483648/swap0,cpuquota1,PID256, read-only
cgroup, UID/GID1000, effective/permitted/inherited caps0,NNP1,no daemon.
Rootless cached image, immutable host lower/private upper+DB.
BootstrapCHOWN/SETUID/SETGID acts only on physical private nodes; all
Nix/builders run after capability drop. Two metadata restarts exposed
pre-normalization 0700 socket-path checks/read-only metadata bind access.
Reordered socket check after normalization/worker drop and made owned
public-metadata top directories0755; private DB remains worker-owned, no FOWNER
or DAC_OVERRIDE added. No builds before those gates.

## Budget review and controls

Read-only runner reviewer `01a10200-5978-74c4-80f2-1de1f0a2a76e` found/rechecked
two P2 budget gaps before any intended native build: interrupted-controller
spending was not persisted, and client exit alone could refund while container
survived. Both fixed: NB serialized controller lock; durable fsync reservation
of ALL remaining budget before launch; private PID1 absolute deadline exits all
namespace builders; container/client termination reserve; refund ONLY trusted
worker completion row plus confirmed container absence, within deadline.
Ambiguity consumes reservation. Six mock-only controls pass: durable prelaunch,
interrupted restart blocked, confirmed completion refund, ambiguous client no
refund, surviving container no refund, concurrent controller blocked. These are
controller tests, not native G4 or producer evidence. Reviewer confirms no
remaining scoped P1/P2 under trust bounds. Cached Podman configured network
helper is pasta, not unavailable slirp4netns; network only scheduled for exact
two-source phase, all other phases network-none.

## Actual attempt and root cause

- Source phase container exits0 in **3.216176885 seconds**, but this is **NOT**
  a successful download: Nix ran0.022893s and returned the two literal `.drv`
  paths.
- MAIN temporary worker mistakenly called `nix build DRV` without an output
  selector. Current Nix treats these as store-path installables, realizing
  derivation FILES, not their outputs. Thus both locked source outputs remain
  absent; no download, writer Rust compilation or fixture compilation/semantic
  run occurred.
- Offline tool phase correctly sees51pending and fails locked-source-validity
  assertion BEFORE `nix build` of writer. No supervisor completion row;
  controller freezes remaining296.783823s reservation. Ledger conservatively
  charged300s, **not a claim300seconds of compilation ran**. No fixture stage
  launched.
- No owned containers remain; immutable lower owner/group/mode0/30000/1775
  unchanged. All76 original source/manifests/locks/expected hashes unchanged.

Temporary worker now passes explicit `DRV^out` installables for every intended
realization. Host offline/no-IFD **dry-run only** confirms exactly the two
locked FODs would build. No fetch/build from this syntax validation. Production
helper, Cargo flags/defaults/compiler, legacy removal and isolated support
unchanged.

## Evidence, retention and renewed gate

Static `evidence/20261003T140800Z-native-target-selection-stop/` retains real
source/tool logs, conservative budget, probe, mock controls, dry-run and honest
summary. Existing readiness/source/constructor evidence remains intact. Producer
`qualified=false / not_proven`; edited semantic/invalidation/freshness still
absent.

Owned `tmp/g4-native-invalidation-20261003T133000Z/` DB/overlay/backend/failed
logs and `tmp/g4-invalidation-readiness/` fixtures retained for
diagnosis/conditional continuation under approved retention; **no newly built
writer cache exists yet**. No post-fix native retry or automatic
refund/reconciliation of frozen reservation. Further realization requires
renewed explicit grant at same bounded target/source scope, not silent recovery
by resetting budget. No refetch expands two locked feeds. Unrelated tmp
unchanged. HEAD/Pvl `5ae0baf0`, Abird `1f4057ee`,190 staged paths preserved; no
index/commit/integration/publication/adoption.

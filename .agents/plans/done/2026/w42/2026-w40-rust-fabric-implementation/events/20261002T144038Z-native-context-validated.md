---
id: 20261002T144038Z-native-context-validated
at: 2026-10-02T14:40:38Z
actor: agent:rust-fabric-main
type: milestone.validated
subject: milestone:bounded-native-context-and-packaging-projection
tags:
  - area:rust
  - kind:validation
  - skill:nix
  - collaboration:parallel
---

# Bounded native caller context validated

- Added only `buildAttrs` to base/composition APIs. Projection derives final
  merged context, promotes ordered caller native inputs and captures nine
  approved env names. Source-only recipes remain unchanged; every ancestor
  reconstructs under actual consumer context. Original default/zero-context
  branches remain exact.
- Expanded producer/member/check/fmt stages exclude packaging hooks/metadata and
  final test toggles. Final packaging disables artifact publication and checks
  standard Cargo artifact paths; it never becomes an admitted compiler handle.
- Projector reviewer `agent:01a0fcfc-694f-74c4-80f2-1c16298c6bba` found two P2s:
  merged check/lint inputs could be lost and lazy env validation could be
  skipped. MAIN repaired both, added regressions; independent recheck confirms
  resolution.
- Routing reviewer `agent:01a0fd03-8947-74c4-80f2-1c18b9aeb514` reports no
  P1/P2. MAIN also removed redundant expanded `checkEnv` shell replay to
  preserve literal values; scoped re-review confirms it and unchanged old
  branches.
- Executed pure checks: 44 projector, 60 native, 103 base, 41 composition, 114
  closure and 90 existing toolchain assertions. Real suites: 104 base/32
  composition/60 portable native in bare/overlaid x86/ARM Linux contexts. 66
  native snapshot assertions include six actual before-phase fixture identity
  comparisons. Existing real toolchain suite passes 18 assertions on both Linux
  architectures.
- Four isolated executions of the actual output-guard script accept clean output
  and reject target directory/archive/dangling prev symlink. No Cargo or builds.
  This checks the shell guard only, not real archive inheritance or target
  reuse.
- New durable native-context note and docs index record contract, fixes and
  limits. Successful snapshots/evaluators/guard outputs are cleaned after
  validation.
- All parallel claims complete. Source work stays unstaged/uncommitted; primary
  masters remain Pvl `5ae0baf0`, Abird `1f4057ee`. No default policy/root recipe
  change, publication, fetch, build/capture or full-root/host evaluation
  occurred.
- Keep plan active. Next code milestones are revision-based
  mirrors/exports/adoption; native/runtime/cost, profile/flag/hook/cross and
  exact-producer gates remain open.

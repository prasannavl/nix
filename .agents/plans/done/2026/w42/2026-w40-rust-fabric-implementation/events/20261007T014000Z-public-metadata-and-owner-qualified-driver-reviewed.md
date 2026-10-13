---
type: validation
actor: agent:rust-fabric-main
plan: 2026-w40-rust-fabric-implementation
tags: [area:rust, g4, cache-custody, source-review]
---

# Public metadata PASS; exact-owner driver source reviewed

## Current continuation — 2026-10-07

Public Cargo metadata inspection now **PASS**, exit0/1.8415283560170792s: 20
inherited metadata records/2920 interpreted bytes and six public Serde source
records/696 bytes. Library encoded dep-info is valid with no tracked paths/env;
four short tokens and both recognized build-script outputs match between
parents. Only their numeric builder root-output paths differ. No missing
inherited metadata; consumer context and required unit outputs remain unproved.
This narrows hypotheses, not CargoFresh or the first rejection. Saved
independent analysis reproduced the records without reopening archives.

A separate reviewed cache diagnostic reached `Physical/physical`. MAIN's finite
stat-only checks found the concrete current custody mismatch:379/381 selected
roots are hostUID/GID1000 (guest0), two host100999 (guest1000), not uniformly
guest1000. Exact per-root pins now replace that false assumption; all
descendants must match their declared root owner before body-open. No blanket
owner alternatives, permissions repair, regular-filechown, hardlinks or
sensitive-name/body exceptions. This is an inspector bug, not a Cargo fix. An
earlier controller refusal was MAIN's wrong authorization tag/scope; old
executed sources and fully charged failures are preserved, not rearmed.

New owner helper freeze56e80f31 is independently SOURCE_REVIEWED with344
normal/-O controls. Complete manager integration is independently
SOURCE_REVIEWED: 60 bindings/37 preserved reviewed-v2
artifacts,196candidate+50independent checks per mode. Separate
readonly/privatePID1 helper20 must precede copying inside one aggregate
nativeA300, not run in the writable consumer guest. Runtime remains
**FAILPREARM** until fresh MAIN custody/body permissions/manifest and explicit
native arming; source approval is not current NAR/WAL/copy proof.

Historical source/metadata **330s fullycharged CLOSED**, no remaining metadata
slot/retry/refund. All six mission native300 ceilings and four direct-module 30s
evaluations remain unarmed. Actual manager/warm/peer/member locality and
immutable mirror/Abird qualification are still pending. Selected HEAD lacks
revision-owned mirror support; dirty support cannot substitute. Unattributed
master89ba1b8 drift is preserved; HEAD/source7/index7812 unchanged. No Git
integration/publication/default adoption/worktree deletion authority.

Evidence: `.agents/runs/rust-causal-metadata-20261006T072156Z/`,
`rust-cache-failure-enum-20261007T010444Z/`,
`rust-cache-physical-saved-analysis-20261007T010444Z/`,
`rust-cache-owner-pin-20261007T012000Z/`, and
`rust-manager-completion-20261006T072156Z/` under the same runs directory.
Append-only event20261007T014000Z records this update; older checkpoints below
remain historical, not live accounting or native authority.

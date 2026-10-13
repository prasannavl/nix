---
id: 20261010T152900Z-staged-corpus-and-script-layout-audit-completed
plan_id: 2026-w40-rust-fabric-implementation
type: review
actor: agent:rust-foundation-main
routing_tags:
  - area:rust
  - task:staged-cleanup-audit
---

# Independent staged-corpus and script-layout audit completed

Auditor `01a12663-e717-77eb-a00f-6dff64a84b92` returned substantive read-only
findings. MAIN persisted them in
`.agents/docs/notes/tooling/rust-foundation-cleanup-audit-2026-10.md` and
updated the docs index/plan/work views. No executable/script path, staged state
or historical payload was changed.

## Exact screenshot population

R: 9400 staged entries (9347 added,20 modified,33 deleted);10558 public indexed
paths. A/default Abird each have4215 public indexed paths and0 staged entries.

R includes4380 evidence entries and4575 acquired upstream Rust/Cargo inputs:
8955 entries /95.3% of the screenshot. The corpus includes an authenticated
516130239-byte upstream release archive,4211 build-asset/vendor-metadata
projection files,360 original Cargo review files, two reports and custody
README. The input custody note says this is research material, not intended Git
publication or a production mirror. Payloads were not read for the audit.

The prior111 public-staging-root cleanup addressed a different population and
intentionally left the indexed/staged corpus/evidence intact. Historical cleanup
receipts are not revised to suggest those9400 entries were removed.

## Implementation and organization

Actual implementation is the flake helper/closure/context/base/export/mirror and
composition code plus the mirror generator/validator. Most flake entries are
functional tests/fixtures, which should not be discarded as evidence clutter.

Qualification modules include fixtures/acceptance and real-binary runners, but
are not production routes. The producer spike is historical research, not a
prerequisite for the selected existing Cargo/Crane route.

Recommended proposal: retain rust-foundation project naming; group active
qualification and mirror tooling under `scripts/rust-fabric/`; retire the probe
from active tooling unless a current research consumer requires it. The audit
identified depth/import/loader/discovery changes needed for mechanical
relocation. No migration was performed; future executable paths need new
qualification bindings before use.

## Current index and remaining permission boundary

MAIN confirmed current R index byte SHA256:
`908e6600def51823f97d38952e6a798c3ec0072820779ab63af8582f9fe9d01c`. The
historical cleanup before/after byte hash was `ea54cb43…`. Cause, staged-content
change and actor/ownership are unknown; metadata refresh is a possibility, not a
finding. No reset, stage, unstage or staging-ownership inference occurred.

Before targeted staged removal: build an exact retention/dependency manifest,
verify authorized retained custody for large research payloads, separate private
payload boundaries and obtain authority covering current staged state. Do not
blanket-reset or duplicate huge payloads into a newly tracked archive. Frozen
history is not rewritten.

Build qualification stays paused pending the framing/value and cleanup/layout
choices. Manager/CargoFresh/full parity/platform/cost remain unproved. No
runtime/build/Nix/Podman/project import, secret read or Git mutation occurred.

---
id: 20261002T205100Z-mirror-validated
at: 2026-10-02T20:51:00Z
actor: agent:rust-fabric-main
type: validation.completed
subject: milestone:revision-mirrors-and-standalone-exports
tags:
  - area:rust
  - authority:code-only
  - evidence:evaluation
  - collaboration:independent-review
---

# Revision mirror code-only closeout

## Decisions and review

Generator, scoped-source and Nix export/adoption claims are complete for this
code-only slice. The canonical plan stays live; integration, root adoption,
producer qualification and runtime/cost gates remain open.

The resource scanner needed iterative repair of root aliases, interpolation,
conditional/file aliases, formal defaults, stored function results and returned
record/list data. It now retains local pathname provenance structurally while
separating code imports/methods from returned pathname data. Canonical service
helper compatibility is tested alongside adversarial synthetic revisions. Exact
root-formal metadata reads require finite regular pinned-blob/output-inventory
presence proof, not module/name exceptions. This is a bounded dialect, not
general Nix interpretation or arbitrary higher-order syntax certification.

Previous generator reviewer `agent:01a0fd37-4c88-74c4-80f2-1c233df77763`
supplied concrete counterexamples through the last record-returned-path defect.
Generator owner `agent:01a0fd21-c136-74c4-80f2-1c1d2aea82b0` repaired it before
its session transport failed; MAIN recovered the already-written patch and reran
validation. No dependency/network fetch was performed by this recovery. The user
prompted continuation after work stalled; recovery was bounded to the concrete
blocker.

Final independent reviewer `agent:01a0fe54-03bc-74c4-80f2-1c6dce184375` found no
concrete P1/P2 after checking all nine returned-record counterexamples,
method/code separation, finite metadata proof and actual pinned service-helper
closure. Earlier Nix/export/adoption reviewer confirmed its output-collision and
workspace-projection repairs with no remaining P1/P2. No interactive revdiff was
requested or used.

## Validation

MAIN reran:

- 80 mirror generator tests; 225 complete support tests; 56 spike tests.
- 13 retained child-ref checks against unchanged root originals.
- Actual restricted offline/no-IFD CLI `--write`, then `--check`: mirror
  matches. Immutable fixture commit object only; no worktree/index source
  overlays.
- Four cached bare/overlaid x86/ARM contexts: 83 scoped-source assertions with
  17 full/scoped identity pairs, 25 in-tree mirror assertions, 25
  generated-entry mirror assertions, 10 inert adoption assertions, 104 existing
  base, 32 existing composition and 60 existing portable native assertions per
  context.
- Pure suites: 114 closure, 103 base, 41 composition, 44 projector, 60 native,
  18 original-definition export assertions.
- Four newly registered shared check derivation paths evaluate without builds.

Formatting, diff whitespace checks and successful owned temporary-state cleanup
are closeout actions recorded in the materialized work README. Synthetic Git
object fixtures are test evidence, not source publication authority.

## Limits and authority

All post-port implementation remains unstaged/uncommitted in the retained
worktree. Masters remain Pvl `5ae0baf0` and Abird `1f4057ee`. No Cargo/native
build, capture, provider/dependency fetch, full-root/host evaluation, deployment
or Git publication was performed. No real secret contents were read.

Source closure/construction/freshness evidence is not resolved units/features,
actual parent archive inheritance, Cargo reuse, effect invalidation, runtime
cost or root/Abird acceptance. Producer qualification remains `not_proven`. A
generated shell cannot rewrite the pristine mirror Cargo manifest. Broad
composition, external adoption and compiler defaults remain unchanged/off unless
explicitly selected. Further builds/integration/publication require separate
authority.

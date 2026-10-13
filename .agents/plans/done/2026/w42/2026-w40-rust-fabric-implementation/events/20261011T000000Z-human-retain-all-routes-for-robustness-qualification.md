---
type: decision
project: rust-foundation
plan: 2026-w40-rust-fabric-implementation
coordinator: MAIN
source: human
state: correctness-qualification-first-acceleration-adoption-undecided
---

# Retain all routes while qualifying robustness

The human answered the workflow/payback question: "lean towards keeping for all
while we test to ensure that we are bug free when we do it for all and it's
robust, since the standalones are easier and more striagh forward if i'm right?"
This follows the earlier decision that native manager/agent development and
standalone/composed delivery are both primary workflows, and the explicit
qualification resume. No numerical frequency, savings threshold or maintenance
horizon was supplied. MAIN does not invent one or interpret testing as default
adoption permission.

The next decision is to retain all original supported candidate routes and
acceptance cases during correctness/robustness qualification. Representative
first case: R native x86_64-linux host-manager with its host-agent dependency,
unchanged original package recipes. The first actual standalone package case is
the exported host-manager constructor; immutable standalone/composed consumer
builds still require genuinely owned support and separate immutable permissions.
Standalone packaging has fewer integration seams but is not already qualified.

Compare the existing Cargo/Crane package constructor, an explicit contextual
member-local closure base with parent=null, and equivalent strict-compatible
subset inheritance. Keep source/lock/full vendor/context/toolchain/features/
targets/checks/hooks/wrappers and finite measurement envelopes equivalent. Do
not use useWorkspaceDeps=false as the no-inheritance comparator: it changes
isolation, not only parent reuse. Current constructor metadata must be genuinely
observed before its recipes can be admitted.

The worthwhile immediate outcome is unchanged semantic behavior and member
locality for both primary workflows, with supported inheritance and immutable
ownership qualified across the original acceptance matrix. This is a test
ordering decision, not a finding that inheritance pays for its upkeep. Actual
incremental compile/fresh work, elapsed time, store footprint and maintenance/
custody cost remain required; acceleration/adoption decisions are deferred until
the real frequency and useful payback can be assessed. Output/version/NAR/JSON
equality is not reuse. No original completion or cost criterion is removed.

Falsifiable stops remain: any source/context/parent/ownership/stat9/resource/
cleanup refusal; noncomparable recipes; unsupported context; or failure of a
single compact admitted original-route attempt to observe the product. Close
each finite unit truthfully, do not replay/refund/renew it, and review the
distinct environmental/policy decision before a diagnostic campaign. Defer
acceleration/adoption if marginal inheritance savings are nonpositive after
upkeep, payback remains undefined, or the relevant workflows cannot be
supported.

Separate correctness/locality, acceleration, input custody and immutable
handoff. Initial actual manager PASS is mandatory before warm follow-ups. Full
standalone/mirror/Abird/platform/24-member cost and PREPARE/COMMIT/integration/
default permissions remain outstanding. This event supplies neither fresh
custody nor executable review or a build scope.

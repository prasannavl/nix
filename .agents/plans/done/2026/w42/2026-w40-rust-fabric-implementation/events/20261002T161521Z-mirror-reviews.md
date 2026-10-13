---
id: 20261002T161521Z-mirror-reviews
at: 2026-10-02T16:15:21Z
actor: agent:rust-fabric-main
type: review.recorded
subject: milestone:revision-mirrors-and-standalone-exports
tags:
  - area:rust
  - collaboration:independent-review
---

# Independent reviews and repairs

Reviewer `agent:01a0fd37-4c88-74c4-80f2-1c233df77763` found:

- P1 supplied Git subdirectory could bypass actual source-worktree output
  boundary. Canonical root admission and ownership-before-output-content
  inspection repaired; private mock blocked synthetic key read. No real secret
  contents read.
- P2 ancestor Cargo config omitted from materialized planner snapshot.
  Metadata-only ancestor/subtree rejection repaired; unsupported configuration
  cannot disappear.
- P2 selected dynamic definitions / computed directory resources could be
  missing while generation and check succeeded. Definition preflight and
  conservative computed resource admission repaired, then recheck found further
  empty-root alias and interpolation bypasses. Generator lane is repairing
  these; publication of this milestone is not yet validated.

Reviewer `agent:01a0fd37-941f-74c4-80f2-1c2450479d95` found:

- P2 generic component keys silently overwrote other members. Repaired with
  Cargo- named packages, namespaced checks/apps and collision rejection; primary
  aliases remain primary. Module collisions reject rather than guess function
  equality.
- P2 `build.src` retained pristine full membership; build `prePatch` projection
  had not run, so exporting it as a usable scratch workspace was incorrect.
  Repaired with separate, explicitly realizable copy plus actual Crane TOML
  serialization, replacing only membership. No package hooks replayed; full lock
  remains.

Nix reviewer confirmed no remaining P1/P2 after rechecks, including inert
adoption and coherent empty-hook shell. Four-context cached validation passes 83
scoped, 25 mirror and 10 adoption assertions. Scope is not incoming-component or
effect proof; neither projection nor cached identity proves Cargo reuse.

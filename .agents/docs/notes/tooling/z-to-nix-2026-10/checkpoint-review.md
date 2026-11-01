# Checkpoint-backed review worktrees

## Completed delivery

- All 227 frozen z commits reviewed across ten batches; 7,474 first-parent
  events independently matched to their ordered ledgers, including merges.
- All ten batches approved, integrated and retired normally. Last series: six
  signed units / 60 paths, `9aecdcdc` → `2c9e2b41`; exact final tree
  `7e0f7389bf8a92b283c16d52eb04f2c91e4aea6b`.
- Actual-main canonical gates, 15 focused check realizations and 179 all-system
  no-build/no-IFD checks passed. Existing VM/test outputs may be reused; this
  receipt is not a claim that every output was freshly compiled or executed.
- User approval of 08–09 includes the formatter/test prerequisite that blocked
  documentation-only 10. No event rewriting, lint bypass or ancestor approval
  was inferred before that authorization. Event 0027 records the transition.
- Original review indexes were preserved until successful main validation, then
  each review detached at its exact approved tree for normal removal. Retain all
  review/checkpoint branches; unrelated worktrees and z note/override untouched.
- Global byte/type/mode/presence compatibility and carry-back remain later.
  Tailscale/unstable hold and Incus downgrade deployment blocker remain.

## Review protocol

- Keep each unapproved review's own delta staged. Create successor checkpoints
  in separate owned temporary worktrees; sign logical code/test/caller/docs
  units, verify signatures, unit paths/modes and exact final index-tree
  equality.
- Remove temporary checkpoint worktrees only when clean; retain their branches.
  Never clear a review merely to create a successor base.
- Integrate approved deltas against actual main, preserving independent changes.
  Documentation-only approval never includes held code ancestors. A disjoint
  receipt may advance a review base only with identical original staged bytes.
- Stage new files before Git-aware Nix validation. Frozen queues and append-only
  event bytes remain unchanged; adaptations/checkpoints add no source rows.
- Revalidate actual main before retirement. Delete only inventoried generated
  artifacts, use normal worktree removal, and preserve unrelated state/refs.
- No push, deployment, secret read, live probe, credential/profile activation,
  branch deletion or destructive rewrite is implied by review/integration.

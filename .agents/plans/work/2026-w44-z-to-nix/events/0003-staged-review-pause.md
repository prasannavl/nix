# Staged delivery correction and review pause

- User requires staged diffs, not committed review batches; pause after batch 01
  remains. Supersedes the commit/automatic-advance instructions in 0001–0002.
- Batch 01's original eight signed commits end at `18239f4d`; retain them on
  `agent/z-to-nix-01` for recovery. No history rewrite or deletion.
- Switch its clean worktree to new `review/z-to-nix-01` at current master
  `e74e990c`; restore only the 24 owned batch paths into index/worktree. Initial
  index tree exactly equals original validated `1c862c17`.
- Add only current workflow evidence after restoration; code/test content and
  modes stay unchanged. Leave everything staged, with no new commits.
- Batch 02 remains untouched at `18239f4d`, with no own delta. After batch 01
  lands, re-anchor the next review onto actual master and stage its remaining
  delta. Updating master does not itself update another worktree's HEAD.
- Automatic recurrence 60994762 is cancelled; explicit instruction is required
  to continue. New commits/checkpoints and main integration need approval.
- Both masters, frozen queue, original events/reports, unrelated worktrees and z
  note/override are preserved. Tailscale hold/deployment blockers remain.

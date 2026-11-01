# Reverse stack authorization

- User authorized the complete reverse pass in 25-source-commit batches, one new
  worktree on each preceding signed tip; continue without review pauses.
- Arithmetic: 227 = nine × 25 + two, so ten review worktrees.
- z prerequisite completed first: signed handoff `8ad96801`, forward worktree
  removed, deferred final unstable/Tailscale patch retained unapplied in Git.
- Both masters are read-only throughout this reverse phase. Integration waits
  for user review and one-by-one approval; final compatibility pass is later.
- Target freezes externally advanced nix `e74e990c`; source window still ends at
  z `b1a0f5bb`. Current z `8ad96801` supplies coherent later fixes where
  identified; generated forward commits do not expand the frozen queue.
- Batch 01 starts clean at target base; other worktrees start only after the
  preceding batch is validated and committed. No subagents or live probes.

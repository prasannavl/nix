# Agent Runs

Use `.agents/runs/<session>/` for temporary execution state that does not belong
to one plan's durable collaboration record. A run may support one plan, several
plans, or plan-independent work.

A run may contain scratch files, temporary logs, partial generated output,
staging copies, and debugging evidence. Identify its actor, scope, related plan
IDs, and Git worktree when those exist.

Use `.agents/runs/locks/` only for temporary cross-agent filesystem locks when
atomic replacement is not possible. A run directory is not a Git worktree; use
`worktrees/<session>/` for isolated Git implementation.

Promote durable outcomes into repository changes or append-only plan events.
Permanent records should reference commits and durable artifacts, not run paths.
Clean successful runs after integration. Retain failed runs only while they are
useful for debugging or when the user asks to keep them.

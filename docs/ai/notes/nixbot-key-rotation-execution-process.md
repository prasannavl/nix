# Nixbot Rotation Execution Process

Date: 2026-02-26

## User Direction
- Create a process that an agent can execute phase-by-phase.
- Require confirmation before each execution step.
- Cover overlap rotation and bastion-first cutover with legacy-node bootstrap handling.

## Output
- Added `docs/ai/playbooks/nixbot-key-rotation-execution.md`:
  - required operator inputs
  - mandatory confirmation protocol
  - Mode A: planned overlap rotation
  - Mode B: bastion-first single-pass cutover with per-host `key` + `bootstrapKey` legacy overrides
  - incident caveat (revoke-first)

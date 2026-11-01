# Reverse stack

Owner: @pvl

Plan: [contract](../../2026-w44-z-to-nix.md)

## Delivery status

- All 227 frozen reverse commits and 7,474 first-parent events reviewed.
- Batches 01–10 integrated; all ten review worktrees retired normally. Signed
  checkpoints/recovery branches remain. Latest approved series: `2c9e2b41`.
- User approval of 08–09 resolved the formatter prerequisite for docs-only 10.
  Event 0027 supersedes earlier held/integration-blocked status; raw evidence
  and historical reports remain unchanged.
- Batch delivery is complete. Global compatibility/carry-back remains the next
  phase; no blanket parity, rollback-safety or deployment-readiness claim.

| Batch | Reverse rows | Global rows | State                                   |
| ----- | ------------ | ----------- | --------------------------------------- |
| 01    | 1–25         | 84–108      | Integrated `472863a5`; worktree retired |
| 02    | 26–50        | 109–133     | Integrated `86b05006`; worktree retired |
| 03    | 51–75        | 134–158     | Integrated `d4c96718`; worktree retired |
| 04    | 76–100       | 159–183     | Integrated `b8af31d6`; worktree retired |
| 05    | 101–125      | 184–208     | Integrated `54f2ce63`; worktree retired |
| 06    | 126–150      | 209–233     | Integrated `05b1e0c5`; worktree retired |
| 07    | 151–175      | 234–258     | Integrated `3ee6f36f`; worktree retired |
| 08    | 176–200      | 259–283     | Integrated `9df47137`; worktree retired |
| 09    | 201–225      | 284–308     | Integrated `33ef9a45`; worktree retired |
| 10    | 226–227      | 309–310     | Integrated `2c9e2b41`; worktree retired |

- Review paths: `/home/pvl/src/nix/worktrees/z-to-nix-NN`.
- Batch-01–10 worktrees are removed after approved, verified integration.
  Recovery branches/history remain, including original signed batch-01
  checkpoint `agent/z-to-nix-01` / `18239f4d`. See event 0006.
- Batch 02 base is actual main `472863a5`; its approved series is split into
  Rust code/tests/guidance, rootless Podman guidance and review evidence.
- Batch 03's checkpoint `d4c96718` reached main after user approval: three
  signed logical commits, exact eight-path tree and repeated main gates. Its
  worktree was removed without force; both branches remain. Events 0008–0009
  record checkpoint creation followed by approved integration/retirement.
- Batch 04's separate checkpoint is `b8af31d6`: two signed logical commits,
  exact tree; original thirteen-path review retained until approval. See
  event 0011.
- Batch 05's separate checkpoint is `54f2ce63`: one signed documentation unit,
  exact tree; six-path original review retained until approval. See event 0013.
- Batch 06's separate checkpoint is `05b1e0c5`: one signed documentation unit,
  exact tree; six-path original review retained until approval. See event 0015.
- Later review HEADs are the preceding signed checkpoint; only the current
  batch's own delta stays staged.
- Batch 07 checkpoint `3ee6f36f` and all approved 04–07 units are now on main;
  their review worktrees are removed normally. Branches remain. Events 0017–0018
  record the checkpoint and approved integration/retirement.
- Batch 08 checkpoint `9df47137`, batch 09 `33ef9a45` and batch 10 `2c9e2b41`
  reached main after approval. Event 0027 records integration, actual-main gates
  and normal retirement; events 0022–0026 retain earlier checkpoint and
  validation states.
- All ten batches delivered. Future code-bearing work still requires approval;
  the completed review does not authorize carry-back or deployment changes.
- No push or deployment. Global compatibility remains later.
- Latest format: tooling note `z-to-nix-2026-10/checkpoint-review.md`.
  Historical staged-review/pause records are superseded, not rewritten.
- Frozen queue remains unchanged; ledgers separate historical review,
  carry-forward adaptations and actual validation.

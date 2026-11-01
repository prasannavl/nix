# Stacked z → nix review

Author: pvl Owner: @pvl

## Delivery status

- All 227 frozen reverse commits and 7,474 first-parent events reviewed.
- Batches 01–10 integrated; all ten review worktrees retired normally. Signed
  checkpoints/recovery branches remain. Latest approved series: `2c9e2b41`.
- User approval of 08–09 resolved the formatter prerequisite for docs-only 10.
  Event 0027 supersedes earlier held/integration-blocked status; raw evidence
  and historical reports remain unchanged.
- Batch delivery is complete. Global compatibility/carry-back remains the next
  phase; no blanket parity, rollback-safety or deployment-readiness claim.

## Contract

- Review all 227 frozen z commits directly; no subagents.
- Ten batches: nine of 25 source commits, then two. Finish automatically and
  report each completion; no per-batch approval pause.
- Batch 01 landed on main `472863a5`. User reviewed batch 02 and authorized its
  signed logical integration, then removal of both clean review worktrees.
  Retain their recovery branches. This supersedes batch 02's unstaged delivery.
- Batches 01–07 are reviewed, approved, integrated and their review worktrees
  retired. The approved series reaches `3ee6f36f`; recovery branches remain.
  Batch 04 selects the repository Stalwart CLI and tests its binding; batches
  05–07 change only `.agents/` review records.
- Code-bearing reviews retained only their own delta staged until approval.
  Latest approval includes batches 08–09; batch 10 is documentation-only. All
  ten are now integrated and retired after actual-main validation.
- Standing approval: when a completed batch's entire own delta is confined to
  `.agents/`, integrate its signed logical documentation units into actual main
  and retire its verified review worktree without another approval. This also
  applies to batch 10; it supersedes staged-only delivery for such batches.
- Documentation-only integration never approves unapproved code ancestors. Apply
  only the owned documentation delta when checkpoint ancestry contains held
  code; preserve main and all other review changes.
- Separate signed `checkpoint/z-to-nix-NN` branches contain each predecessor's
  logical commits for the next base. Checkpoint commits are authorized; do not
  clear or commit an unapproved review worktree's visible delta. Use a separate
  owned temporary worktree and verify exact candidate tree, paths and modes.
- Further code-bearing integration requires separate user approval. Moving main
  does not update other HEADs/indexes; later re-anchoring must preserve each
  staged delta and intervening user work. Never copy an older cumulative tree
  over main. Disjoint approved documentation receipts may advance a review base
  by fast-forward only when its original staged delta remains byte-identical.
- No pushes, deployments, live probes, credentials/profile activation, branch
  deletion or history rewrites.
- Preserve nix identity/MIT licensing, host/user policy, Dotlink and other local
  inputs, Rust composition/lock policy and identity-owned tests. No blanket tree
  replacement or revival of retired layouts/private products.
- Share complete implementation/test/caller units. Later source fixes may be
  used to keep a unit coherent; identify them in its ledger. Portable changes
  created during forward reconciliation remain explicit carry-forward units, not
  extra entries in the frozen source queue.
- Final global byte/type/mode/presence compatibility pass is a later phase.
  Per-batch exact-path/preservation checks are not a blanket parity claim.
- z unstable/Tailscale final update stays deferred in z's tracked unapplied
  patch. Do not downgrade nix's newer Tailscale or change restart policy. Incus
  downgrade safety remains an independent deployment blocker.

## Baselines

- Source window: `13dafcdedeb2362ae670b65437a5a26af677f75a` →
  `b1a0f5bb4f57e2a7c6ea2648deed412c42d33171` (227 commits).
- Current source reference: z `8ad96801da28a8feaada5f2de3ce8191b1def099`.
- Initial target: nix `e74e990c65cd76b9b418a22c50a416a03e960bf1`; its Dotlink
  lock differs from old `ae477b88`. Before batch 01 integration, external main
  advanced to `91ad59db` with three Dotlink host changes. All are preserved.
- Batch 02 base: integrated main `472863a548f972f0e723a7e9049d340fb50a2cd3`.
- Complete-DAG queue: `z-to-nix-2026-10/source-queue.tsv` in tooling notes;
  SHA-256 `ff8e15891c1843ed851547b865ea8a6c4eaadf162892672617638c14d7bd05cc`.
  Reverse rows are 84–310. Merge deltas use first parents.

## Method

1. Review intent and every changed path; secret-bearing paths by filename only.
2. Record adopted, adapted, already adopted/superseded, or retained-policy
   dispositions and proof. Current source/tests outrank stale intermediate
   implementations. A missing path is not silently treated as shared equality.
3. Validate canonical format/lint, affected synthetic/package checks and exact
   touched-path types/modes. Preserve caller-owned default behavior.
4. Stage explicit paths for Git-aware validation; record HEAD, candidate tree
   and predecessor boundary. Leave each unapproved review delta staged. Create
   needed successor checkpoints separately in signed logical code/test/caller/
   docs units; verify exact final trees and retain checkpoint branches.
5. For approved integration, preserve actual main and independently advanced
   changes; verify signatures and exact candidate tree before clean-worktree
   removal. Start the next batch from the integrated or checkpoint tip. Preserve
   historical evidence, queues and all other worktrees.

## Evidence

- Live state: `work/2026-w44-z-to-nix/README.md` and append-only `events/`.
- Commit/path ledgers: `.agents/docs/notes/tooling/z-to-nix-2026-10/`.
- Prior forward reports remain in z; no historical report/queue rewriting.

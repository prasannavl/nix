# Approved batches 04–07 integrated and retired

- User explicitly approved batches 04–07 for main integration and sidetree
  removal. Batch 04 contains the Stalwart CLI binding fix/regression; batches
  05–07 contain only `.agents/` review records.
- Clean main fast-forwarded from `d4c96718` to
  `3ee6f36fbe6c7793433a801272e538a0f0cf42be`: five signed logical commits, 25
  exact approved paths, tree `c9e4c03e25beb122628bc4383c075292d15a8ce3`.
- Actual-main offline format/lint, five focused Stalwart/repository/no-IFD
  checks and all-system no-build/no-IFD evaluation passed. This is not fresh
  compilation of every package or live service acceptance.
- All four review indexes matched their signed checkpoints before retirement.
  Detached at the identical approved trees, removed only the inventoried
  generated Ruff caches, then removed clean worktrees normally. All branches,
  unrelated worktrees, source note/override and batch 08 staged work preserved.
- Standing approval: completed batches whose entire own delta is under
  `.agents/` may integrate and retire automatically, including the last batch.
  No implicit approval of unapproved predecessor code. Code-bearing batches
  still require separate approval for main integration.
- Disjoint documentation closeout may fast-forward the active review base only
  with its original staged delta unchanged. No stash, force, reset or push.
- Frozen queue, inputs/Dotlink, identity/tests and newer nix Tailscale retained.
  Incus downgrade remains a deployment blocker; no live operation performed.

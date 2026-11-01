# Batch 03 — approved integration and retirement

- User reviewed batch 03 and explicitly requested main integration and sidetree
  deletion. This supersedes its staged-only delivery, not later batches.
- Clean main fast-forwarded `86b05006` →
  `d4c96718e0e925776073e12dcd05c1be09ea6df7`; three signed logical commits from
  event 0008, exact reviewed tree `15c87dbc2885b8e9cc6aff435bedfd2f0ac9e3cf`.
- Verified all eight owned paths/bytes/modes, signatures and unchanged other
  refs. Read-only canonical lint and nine focused checks passed on actual main;
  main remains clean. Original canonical format/negative-control/all-system
  evidence remains in the batch-03 report.
- Only then detached the approved review at the identical integrated tree,
  removed its inventoried generated Ruff cache, and removed
  `worktrees/z-to-nix-03` normally, without force. No branch deletion or history
  rewrite: `review/z-to-nix-03` remains at `86b05006`, checkpoint at `d4c96718`.
- Batch 04 HEAD/index/files were preserved exactly; its existing `d4c96718` base
  now equals main. Later documentation records this approval. No batch-04
  integration or retirement is authorized.
- Source z, its unrelated note/override, immutable source queue, exact inputs,
  Dotlink and all unrelated worktrees remain unchanged. No push or deployment.

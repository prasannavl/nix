# Batch 03 — separate successor checkpoint

- Review remains `review/z-to-nix-03` at `86b05006`: eight own paths staged, no
  review commit or unstaged delta.
- Separate `checkpoint/z-to-nix-03` signed series:
  - `b7a47731542b381a2eb7ce43a6413c508e04b63e` — normalization fixture.
  - `804a3d256db0c99dcb7c1dcec77137edd4e5196f` — contributor links.
  - `d4c96718e0e925776073e12dcd05c1be09ea6df7` — review evidence.
- Exact validated/review/checkpoint tree:
  `15c87dbc2885b8e9cc6aff435bedfd2f0ac9e3cf`.
- All signatures, path boundaries, bytes/modes and unchanged review index
  verified. Clean temporary checkpoint worktree removed without force;
  checkpoint branch retained. No main integration.
- Batch 04 starts at that tip; main remains `86b05006`, source z `8ad96801`.
  Prior worktrees 01/02 remain retired; all recovery branches remain.

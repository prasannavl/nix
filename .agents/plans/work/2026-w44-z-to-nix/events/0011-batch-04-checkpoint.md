# Batch 04 — separate successor checkpoint

- Review `review/z-to-nix-04` remains at `d4c96718` with thirteen own paths
  staged; no review commit or unstaged delta.
- Signed `checkpoint/z-to-nix-04` series:
  - `400913c164a12626557a93f1a472f234f8d4908d` — CLI binding and regression.
  - `b8af31d6a4fa09362e02f0e129f4aea4ce04712a` — review evidence.
- Exact candidate/index/checkpoint tree:
  `7488998991942a67dfff5480dc2704e0a40613f7`.
- Canonical fmt/lint, five focused checks, old-overlay negative control, 22
  synthetic helper tests, three-system selection, reused CLI version/help,
  all-system no-IFD evaluation and exhaustive preservation guards passed.
- Signatures and logical path/mode boundaries verified; clean temporary
  checkpoint worktree removed normally, checkpoint branch retained.
- Batch 05 starts from that tip. Main stays `d4c96718`; source z `8ad96801`. No
  batch-04 integration or review-worktree retirement is authorized.

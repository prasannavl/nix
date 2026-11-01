# Batch 09 checkpoint

- Signed units: `a6bfee8a` shared routing/output/services/tests and `33ef9a45`
  review evidence. Final tree `944fe885d788096d2ee03dcf5b87ab4f8d329dcc` equals
  the original review index; both unit trees independently previewed.
- Final reported-tree canonical gates, nine focused checks, six old-code
  controls, package-owned Nix lint and all-system no-build/no-IFD evaluation
  passed. 179 check names unchanged; 64 package derivations identical and 12
  changes confined to Linux host tools plus fmt/lint wrappers.
- Source-filtered sandbox tests include 333 Bash tests, 160 agent library tests,
  400 manager library tests, 72 CLI tests and all manager integrations. One CI
  fixture was isolated from ambient Git cwd after the sandbox caught it;
  production rejection and assertions retained. No private product acceptance.
- Original batch 09 remains at `9df47137` with 42 owned paths staged. Batch 08
  remains at `9aecdcdc` with its sixteen-path tree `9ce141a1` unchanged.
  Temporary checkpoint worktree removed normally; both signed branches retained.
- Main remains `9aecdcdc`; neither code-bearing batch is integrated. Source
  remains `8ad96801`; no push, deployment, live probe or credential operation.
- Final two frozen commits continue in batch 10 from `33ef9a45`. An entirely
  `.agents/` own delta may integrate automatically, but must not import held
  batch-08/09 code ancestors. Global convergence and carry-back remain later.

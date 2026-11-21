# Reference this repo's own flake from impure contexts (updaters, installer).
# Force the Git fetcher in a checkout: the path fetcher walks Git-ignored
# `worktrees/` and fails on unreadable leftovers. Fall back to a path otherwise.
# Callers pass the repo root; don't self-locate (a store-copied flake would
# resolve against the copy). `git+file://` needs `--impure` under `--expr`.
{repoRoot}: let
  root = toString repoRoot;
in
  if builtins.pathExists "${root}/.git"
  then builtins.getFlake "git+file://${root}"
  else builtins.getFlake root

# `lib/internal` to `lib/flake` rename

- Renamed `lib/internal` to `lib/flake` to make the directory purpose clearer.
- Updated the root flake import and `pkgs/` flake-tree import to use the new
  path.
- Updated repo/docs references so `lib/internal` is no longer the canonical name
  for these helpers.

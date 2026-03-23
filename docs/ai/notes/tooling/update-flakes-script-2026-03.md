# update-flakes.sh

Added `scripts/update-flakes.sh` to update all flake lock files in the repo.

- Updates root flake first, then discovers and updates all child flakes.
- Excludes `worktree/` directories.
- Motivated by the lack of a native `nix flake update --recursive` and the pain
  of keeping child `flake.lock` files in sync manually.

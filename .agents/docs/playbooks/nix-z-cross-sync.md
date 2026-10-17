# Nix ↔ z cross-sync

`nix` (open source, MIT) and `z` (private infrastructure) are the same monorepo
in two lineages, cross-wired by local remotes:

- `~/src/nix` → `origin` `git@github.com:prasannavl/nix.git`, plus `abird` → the
  local `z` checkout.
- `z` → `origin` `ssh://github.com/abird-ai/z`, plus `pvl` → the local `nix`
  checkout.

Most files are shared and should stay byte-identical between the two. A small
set of surfaces is **intentionally divergent** and must not be overwritten when
syncing:

| Surface                   | `nix` (open, MIT)        | `z` (private)        |
| ------------------------- | ------------------------ | -------------------- |
| `LICENSE`                 | MIT file                 | absent               |
| README `## Contributing`  | open invite              | internal access note |
| README `## AI disclosure` | open framing             | private framing      |
| README `## License`       | MIT                      | all rights reserved  |
| `CONTRIBUTING.md` intro   | open contributor framing | internal framing     |

## Safe sync order

1. Reconcile the receiving side (`git fetch`, then `git merge --ff-only` while
   the tree is clean).
2. Land shared changes on the canonical side.
3. Fast-forward the cross-remote.
4. Re-apply the divergent surfaces on the side that owns them: `nix` keeps MIT
   and the open framing; `z` keeps the closed surfaces.
5. Verify the shared set still diffs clean (for example `git diff --no-index` on
   the shared files) and the divergent files remain untouched.

Do not push either remote without explicit user confirmation.

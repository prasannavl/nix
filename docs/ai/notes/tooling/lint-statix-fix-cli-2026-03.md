# Lint statix fix CLI constraint - 2026-03

- `scripts/lint.sh` must not pass multiple positional file arguments to
  `statix fix`.
- The current `statix fix` CLI accepts a single optional `TARGET`
  (`statix fix [OPTIONS] [--] [TARGET]`), so diff-scoped and full-repo file-list
  handling must invoke it once per selected file when operating on explicit
  paths.
- `statix check` can still be run per file as before; the key regression was
  only in the autofix path.

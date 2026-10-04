# Update Script Flake Discovery

## Task

`scripts/update.sh --only-flake` failed while a design-g4 probe was in progress:

```text
==> Updating child flake: tmp/design-g4/probe/vendor/sharded-slab
error: Path 'tmp/design-g4/probe/vendor/sharded-slab/flake.nix' in the repository
"/home/pvl/src/nix" is not tracked by Git.
```

The user asked why the updater was reading inside `tmp/` and requested a robust
fix that mirrors `scripts/support/update-helper.py`.

## Root cause

`find_flakes()` in `scripts/update.sh` walked the whole repository with `find`
and only pruned `worktrees/` and `target/`:

```bash
find "$REPO_ROOT" \
    -path '*/worktrees' -prune -o \
    -path '*/target' -prune -o \
    -name flake.lock -print0
```

A `cargo vendor` tree under `tmp/design-g4/probe/vendor/sharded-slab` carries
the upstream crate's `flake.nix`/`flake.lock`. `tmp/` is Git-ignored
(`.gitignore`), so Nix cannot see the untracked `flake.nix`, but `find` does not
consult Git and treated the vendored flake as a repo child flake.

## Decision

Move child-flake discovery into `update-helper.py` as a new offline `flake-dirs`
subcommand and have `update.sh` consume it. This mirrors the existing
consolidation ("one update helper") direction and the `discover_wrappers`
discipline: walk with `os.walk`, never descend into `.git` or generated trees,
and reject unsafe conditions.

Discovery must match what Nix can see. `flake-dirs` therefore also prunes every
Git-ignored **directory**, obtained read-only and offline from
`git ls-files --others --ignored --exclude-standard --directory -z`. Only
directories are pruned: Git ignores nested `flake.lock` files too, but a child
lock's parent directory is not itself ignored, so the two real child flakes
(`pkgs/tools/abird-host-agent`, `pkgs/tools/abird-host-manager`) remain
updateable. Non-Git trees fall back to the fixed generated names (`.git`,
`.direnv`, `node_modules`, `target`, `dist`, `tmp`, `worktrees`).

Output is NUL-separated; `update.sh` reads it with `mapfile -t -d ''` and fails
loudly when discovery yields nothing, so a helper/git failure cannot silently
skip child locks. The root flake is still updated and declared child refs are
still synchronized before child locks, preserving the previous order.

## Validation

- `python3 scripts/support/update-helper.py flake-dirs --null --root "$PWD"`
  returns the root and the two child flakes only; `tmp/` is absent.
- New `scripts/support/tests/test_update_helper_flake_dirs.py` covers sorted
  discovery, Git-ignored pruning, non-Git fallback names, NUL/newline output,
  dispatch isolation, and failure status.
- `test_update_helper_child_refs.py` shell-order test now emulates the
  `flake-dirs` call; all 59 pass. CLI cross-boundary cases reject
  `--null`/`--check`/`--write`/`--jobs` on the wrong subcommand.
- Full `scripts/update.sh --only-flake` completes with exit 0 and no longer
  enters `tmp/`.

## Ownership boundary

- `scripts/support/update-helper.py` owns child-flake discovery (`flake-dirs`)
  alongside `report-sources` and `child-refs`.
- `scripts/update.sh` owns orchestration order and user-facing output only.

## Source of truth files

- `scripts/update.sh`
- `scripts/support/update-helper.py`
- `scripts/support/tests/test_update_helper_flake_dirs.py`
- `scripts/support/tests/test_update_helper_child_refs.py`
- `scripts/support/tests/test_update_helper_cli.py`

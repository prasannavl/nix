# Flake Architecture — Consolidated Notes

- Date: 2026-03-22 (consolidated)
- Scope: repo-local package tree, flake output model, auto-discovery, shared
  helpers

## Flake output model

The root flake exposes repo-local packages through a custom `pkgs.<system>.*`
output rather than cramming everything into the standard `packages`/`apps`
outputs:

- `pkgs.<system>.*` contains derivations usable with `nix build` and `nix run`.
- Runnable sub-targets (e.g. `deploy`) are attached as nested attributes so
  paths like `.#pkgs.x86_64-linux.<app-name>.<target>.deploy` work.
- Deploy host discovery uses
  `nix eval --json path:.#nixosConfigurations --apply builtins.attrNames`
  instead of `nix flake show`.

Key constraints that drove this shape:

- Pure flake evaluation lacks `builtins.currentSystem`, so a custom top-level
  tree must be system-keyed explicitly.
- `nix flake show` validates standard outputs strictly; nested app and package
  trees cannot both be represented there.
- `path:.#...` must be used for working-tree evaluation (Git-backed
  `nix run
  .#...` excludes untracked files).

## Auto-discovery (flake-tree collector)

A shared helper at `lib/flake/flake-tree.nix`:

- Recursively discovers child directories containing `flake.nix`.
- Uses each child flake's `packages.default` as the primary leaf in the custom
  `pkgs` output.
- Preserves extra `packages.*` aliases as attributes on that leaf so nested
  installables keep working.

Adding a new package means adding its directory and `flake.nix`; the parent
collector needs no per-project wiring.

## `lib/flake` directory

Shared flake helpers live under `lib/flake/` (renamed from an earlier
`lib/internal/` to clarify purpose). Key files:

- `lib/flake/flake-tree.nix` — auto-discovery collector described above.
- `lib/flake/packages.nix` — composes the canonical package set for the root
  flake.

The root flake import and `pkgs/` tree both reference `lib/flake/` as the
canonical path.

## Package set architecture (hybrid model)

- Canonical package definitions live in package-local `default.nix` files (e.g.
  `pkgs/<name>/default.nix`).
- Internal package composition uses direct Nixpkgs-style references through
  `lib/flake/packages.nix`, not child-flake input plumbing.
- Child `flake.nix` files serve as **wrapper flakes** for local developer UX:
  per-project `nix run`, `nix develop`, and IDE-friendly subproject workflows.
- The root flake exports installables from the canonical package tree directly,
  keeping one source of truth for builds without sacrificing local per-project
  flake ergonomics.

## Superseded notes

The following files are superseded by this consolidated document:

- `root-flake-app-exports-and-git-source-2026-03.md`
- `auto-discovered-flake-collectors-2026-03.md`
- `lib-flake-rename-2026-03.md`
- `pkgs-hybrid-package-set-and-wrapper-flakes-2026-03.md`

# Flake Architecture — Consolidated Notes

- Date: 2026-03-22 (consolidated)
- Scope: repo-local package tree, flake output model, auto-discovery, shared
  helpers

## Flake output model

The root flake exposes repo-local packages through standard `packages`/`apps`
outputs, while still keeping a custom `pkgs.<system>.*` tree for non-standard
nested package organization:

- Root-exported installables use short commands such as `nix build .#<name>` and
  `nix run .#<name>`.
- `pkgs.<system>.*` still contains the full package tree for nested organization
  where needed.
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

## App metadata contract

- Package `meta.mainProgram` is the single source of truth for runnable app
  binaries.
- Root app generation should derive app entries from package metadata rather
  than from package-local self-referential app passthru wiring.
- Non-standard root flake outputs such as `pkgs` and `nixosImages` are
  intentional. Lint may filter those warnings rather than treating them as
  architectural mistakes.

## Superseded notes

The following files are superseded by this consolidated document:

- `root-flake-app-exports-and-git-source-2026-03.md`
- `auto-discovered-flake-collectors-2026-03.md`
- `lib-flake-rename-2026-03.md`
- `pkgs-hybrid-package-set-and-wrapper-flakes-2026-03.md`
- `docs/ai/notes/apps/flake-app-meta-simplification-2026-03.md`

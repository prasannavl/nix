# AI Nix Evaluation Source Refs (2026-05)

## Scope

This note applies to AI-agent validation commands in this repo: `nix eval`,
`nix run`, `nix build`, `nix flake check`, `nix flake show`, `nix develop`, and
`nix shell --inputs-from`.

## Rule

- Do not use explicit `path:` flake refs for AI-driven repo evaluation.
- Use Git-aware refs so Nix snapshots the tracked repo state and does not copy
  ignored or untracked build output such as `target/`, `tmp/`, `.direnv/`, or
  `result`.
- From the repo root, prefer `.`:

  ```bash
  nix eval .#packages.x86_64-linux.example-hello-rust.src
  nix run .#lint
  nix build .#nixosConfigurations.pvl-x2.config.system.build.toplevel
  nix flake check --no-build .
  ```

- From outside the repo, use the absolute repo path without a `path:` prefix:

  ```bash
  nix run /home/pvl/src/nix#lint
  nix eval /home/pvl/src/nix#nixosConfigurations.pvl-x2.config.system.build.toplevel.outPath
  ```

- For an intentionally committed snapshot, use a Git flake ref:

  ```bash
  nix build 'git+file:///home/pvl/src/nix?rev=<commit>#<attr>'
  ```

## Disallowed forms

These command shapes copy ignored and untracked working-tree content into the
Nix store and can create very large `/nix/store/*-source` paths:

- `nix eval`, `nix run`, `nix build`, or `nix flake check` with an explicit
  path-scheme flake ref for the current directory, `$PWD`, or the repo root.
- `nix shell --inputs-from` with an explicit path-scheme flake ref.

## If untracked files are involved

If a validation appears to require untracked files, stop and make the state
explicit before evaluating. Prefer one of:

- use a Git-aware ref after the files are intentionally tracked;
- validate the specific file/module directly without converting the whole repo
  to a `path:` flake input;
- ask the user before using any command shape that would snapshot untracked or
  ignored content.

Do not use `path:` as a convenience shortcut during AI evaluation.

## Self-referencing flakes from Nix expressions

- `builtins.getFlake "/abs/repo"` inside a `nix build --impure --expr` resolves
  to a `path:` input, even when the path is a Git repository. The path fetcher
  descends into git-ignored linked worktrees under `worktrees/` and fails on
  unreadable leftovers (for example mode-`000` test fixtures under `tmp/`).
- Force the Git fetcher through the shared helper `lib/flake/repo-flake.nix`,
  which keeps the fetcher choice in one place and falls back to a plain path for
  non-Git exports:

  ```nix
  flake = import ${REPO_ROOT}/lib/flake/repo-flake.nix {repoRoot = ${REPO_ROOT};};
  ```

  From another Nix file, use
  `import ./relative/path/repo-flake.nix {inherit repoRoot;}`.
- The helper's `git+file://` branch needs an impure evaluation context. Pass
  `--impure` for `--expr`; in practice `--file` evaluations rooted in the
  checkout accept the ref without `--impure`.
- Do not re-derive `builtins.getFlake "git+file://..."` at call sites. This is
  the shared behavior for `lib/ext/*/update.sh`, `pkgs/ext/*/update.sh`, and
  `lib/installer/build-image.nix`; the `self-reference-fetcher` lint step
  enforces it. See
  `.agents/docs/notes/apps/tailscale-upstream-package-2026-05.md`.

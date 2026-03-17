# Root Flake App Exports And Git Source

- Date: 2026-03-16
- Scope: root flake app/package exports under `apps/`

## Context

The root flake originally exposed nested attrsets like
`apps.<system>.apps.hello-rust.run`, which made `nix run .#apps.hello-rust` fail
because `hello-rust` itself was not an app definition.

Separately, `nix run .#...` evaluated the Git-backed flake snapshot, which
excluded the new untracked `apps/` tree. `path:.#...` worked because it used the
working tree directly.

## Decision

Expose leaf app/package nodes as the runnable/buildable value itself while also
keeping explicit alias attributes like `.run`, `.deploy`, `.build`, and
`.default` on those same leaves.

## Result

- `nix run path:.#apps.hello-rust` works.
- `nix run path:.#apps.hello-rust.run` still works.
- `nix run .#apps.hello-rust` works after the relevant files are tracked by Git
  (for example via `git add`).

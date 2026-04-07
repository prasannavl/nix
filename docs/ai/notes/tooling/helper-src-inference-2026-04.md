# Helper `src` Inference

- Date: 2026-04-07
- Scope: `lib/flake/pkg-helper.nix`, package `default.nix` files under `pkgs/`

## Decision

Common package helper wrappers may infer `src` from `build.src` instead of
requiring packages to pass the same source path twice.

This now applies to:

- `mkGoDerivation`
- `mkPythonDerivation`
- `mkWebDerivation`
- `mkStaticWebDerivation`
- `mkRustDerivation`

## Why

- Many package definitions repeated `src = ./.;` in both the helper call and the
  inner build derivation.
- For the derivation builders used here, `build.src` is available during
  evaluation, so the helper can reuse it directly.
- This keeps package definitions shorter without changing the package name,
  checks, dev shell, or root flake exports.

## Consequences

- Packages using those helpers should usually set `src` only on the inner build
  derivation.
- If a future build derivation does not expose `src`, the helper still supports
  passing `src` explicitly and now throws a clear error when neither source is
  available.
- `mkShellScriptDerivation` still needs explicit `src` because its `build` value
  is commonly a `writeShellApplication` derivation that is not the source of
  truth for project-tree operations.

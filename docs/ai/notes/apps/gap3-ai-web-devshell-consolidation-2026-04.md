# gap3-ai-web dev shell consolidation

- Date: 2026-04-05
- Scope: `pkgs/gap3-ai-web/{default.nix,flake.nix}`

## Decision

Move the `gap3-ai-web` development shell definition into the package-local
`default.nix` and expose it through `passthru.devShell`.

## Why

- Keep `default.nix` as the canonical definition for both build and local
  development ergonomics.
- Let the sub-flake stay a thin wrapper that only re-exports package-defined
  outputs.
- Deduplicate the shared Trunk/WebAssembly environment setup between the build,
  the `gap3-ai-web-dev` helper, and `nix develop`.

## Applied shape

- `default.nix` defines shared tool lists and shell initialization once.
- `flake.nix` wires `packages.dev` to `build.dev` and `devShells.default` to
  `build.devShell`.

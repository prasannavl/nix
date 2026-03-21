# Pkgs Hybrid Package Set And Wrapper Flakes

- Date: 2026-03-21
- Scope: repo-local package architecture under `pkgs/`

## Decision

- Keep canonical package definitions in package-local `default.nix` files.
- Compose shared internal packages through `lib/flake/packages.nix`.
- Keep child `flake.nix` files as wrapper flakes for local developer UX.
- Export root-flake repo-local package installables directly from the canonical
  package tree instead of a child-flake collector.
- Avoid child-flake-only sibling dependency wiring for the canonical package
  graph.

## Rationale

- Internal package composition should stay simple, Nixpkgs-style, and use direct
  package references rather than child-flake input plumbing.
- Wrapper flakes are still useful for package-local `nix run`, `nix develop`,
  and IDE-friendly subproject workflows.
- This keeps one source of truth for package builds without giving up local
  per-project flake UX.

## Initial Coverage

- `pkgs/hello-rust/default.nix`
- `pkgs/nixbot/default.nix`
- `lib/flake/packages.nix`

Wrapper flakes for `hello-rust`, `nixbot`, and `cloudflare-apps` now reuse that
model to varying degrees, with `hello-rust` and `nixbot` fully self-contained
for local standalone wrapper use.

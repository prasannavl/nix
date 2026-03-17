# Auto-Discovered Flake Collectors

- Date: 2026-03-16
- Scope: `apps/default.nix` and the shared collector

## Context

The root collector repeated the same manual steps for each child flake:

- import the child `flake.nix`
- evaluate `packages` and `apps` for one system
- re-export nested namespaced leaves
- add flat compatibility aliases such as `hello-rust-run`

That made every new app require boilerplate edits in the parent collector.

## Decision

Add a shared collector at `lib/flakelib.nix` that:

- recursively discovers child directories containing `flake.nix`
- uses the child flake's own `packages.default` and `apps.default` as the
  primary leaf exports
- preserves any extra child aliases as attributes on the leaf and as flat
  compatibility aliases

## Result

Adding a new app mostly means adding its own directory and `flake.nix`; the
parent `default.nix` no longer needs per-project wiring.

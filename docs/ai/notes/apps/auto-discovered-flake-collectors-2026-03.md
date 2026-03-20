# Auto-Discovered Flake Collectors

- Date: 2026-03-16
- Scope: `pkgs/default.nix` and the shared collector

## Context

The root collector used to repeat the same manual steps for each child flake:

- import the child `flake.nix`
- evaluate `packages` and `apps` for one system
- re-export nested namespaced leaves That made every new package require
  boilerplate edits in the parent collector.

## Decision

Add a shared flake tree helper at `lib/internal/flake-tree.nix` that:

- recursively discovers child directories containing `flake.nix`
- uses the child flake's own `packages.default` as the primary custom root
  export leaf
- preserves extra `packages.*` aliases as attributes on that leaf so nested
  installables like `.#pkgs.<system>.<name>.deploy` keep working

## Result

Adding a new package mostly means adding its own directory and `flake.nix`; the
parent `default.nix` no longer needs per-project wiring.

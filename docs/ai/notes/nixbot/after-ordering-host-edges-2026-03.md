# Nixbot After Ordering Host Edges (2026-03)

## Scope

Add host-level `after = [ ... ]` ordering edges to `hosts/nixbot.nix` without
changing existing hard dependency semantics.

## Rules

- `hosts.<name>.deps` remains the hard dependency edge:
  - selected hosts expand to include their `deps`
  - deploy ordering respects `deps`
- `hosts.<name>.after` is ordering-only:
  - it does not expand host selection
  - it only affects ordering when both hosts are selected
- The effective ordering graph is `deps + after`.
- Unknown `after` targets are fatal.
- Cycles across the combined `deps + after` graph are fatal.
- Existing build and deploy failure semantics remain unchanged; `after` does not
  introduce optional or soft-failure behavior.

## Implementation Notes

- Selection expansion still reads only `deps`.
- Topological ordering and deploy-wave level assignment read both `deps` and
  `after`.
- `--bastion-first` keeps its current precedence over normal ordering edges.

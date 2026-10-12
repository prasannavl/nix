# Plans Index

Use this index as the canonical map for `.agents/plans/**`.

## Upstream

- `.agents/plans/upstream/nixos-lxc-runtime-system-links.md`: Draft upstream
  NixOS/nixpkgs plan for fixing LXC `/run/current-system` loss, distrobuilder
  generator store-path assumptions, special-filesystem ownership, and early
  udev/networkd boot failures.

## Rust foundation

- `2026-w40-rust-fabric-implementation.md`: active P2 coordination plan;
  qualification is paused.
- `work/2026-w40-rust-fabric-implementation/README.md`: main-worktree agent
  route only. The R worktree contains the materialized active work, sources,
  receipts and raw events.
- `../docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`:
  synchronized current truth, original goals, remaining gates and regeneration
  instructions.

The main worktrees contain no duplicate qualification evidence. The active
implementation remains in the explicit Pvl and Abird worktrees. This plan does
not close the independent host-manager/Nixbot integration or generic
multi-ecosystem work.

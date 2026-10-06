# Niri Sway-like Features Plan

Design and implementation plan for two sway-like features in niri, verified
against niri `v26.04` (the version `pkgs.niri` resolves to in this repo).

- Feature 1: always-present numbered workspaces `1`..`10`.
- Feature 2: non-scrolling, screen-constrained tiling (use the niri column/tile
  model, but resize everything to fit the visible area instead of extending
  off-screen).

## Current state

- Feature 1 is **already supported by config**, no code change needed. See
  `docs/wiki/Configuration:-Named-Workspaces.md`: "named workspaces always
  exist, even when they have no windows".
- Feature 2 **does not exist**. Niri is a scrollable tiling compositor by design
  (`README.md`), and `niri-config/src/layout.rs` (`Layout` at line 11,
  `LayoutPart` at line 98) has no non-scrolling / fit option. It has to be
  patched.

## Feature 1: fixed workspaces 1..9 + niri's unnamed tail (config only)

Implemented as `1`..`9` with index-based binds (`Mod+0` targets niri's unnamed
10th); see `.agents/docs/notes/apps/niri-fixed-workspaces-2026-10.md`. The
original sketch below is kept for context.

Add named workspace declarations and focus bindings to
`users/pvl/niri/config.nix`:

```kdl
workspace "1"
workspace "2"
// ...
workspace "10"

binds {
    Mod+1 { focus-workspace "1"; }
    // ... through
    Mod+0 { focus-workspace "10"; }
}
```

Details and caveats:

- Quote the names: in KDL `focus-workspace 1` parses as
  `WorkspaceReferenceArg::Index` (first workspace), while `focus-workspace "1"`
  parses as `WorkspaceReferenceArg::Name` (`niri-ipc`). The current config has
  no `focus-workspace` bindings at all, only `Mod+Shift+N` move bindings.
- Named workspaces are created in declaration order and persist when empty.
- They distribute across outputs. To pin a workspace to an output, use
  `workspace "N" { open-on-output "..." }`, and use the output names already
  wired in `users/pvl/wm/outputs.nix`.
- `set-workspace-name` / `unset-workspace-name` exist (since 25.01) if the
  static set ever needs to become dynamic again.
- Optional: per-workspace `layout {}` overrides are supported (since 25.11),
  which is where feature 2 could be enabled for the laptop output only.

## Feature 2: constrained ("fit-columns") tiling

### Niri layout model in one paragraph

A workspace has an ordered list of **columns**; a column holds one or more
**tiles** (stacked/tabbed). Column positions come purely from accumulated
widths: `ScrollingSpace::column_xs` (`src/layout/scrolling.rs:2304`) walks
`data[i].width + gaps` left to right, and `tiles_with_render_positions`
(line 2377) subtracts `view_pos()` (line 2294), where
`view_pos = column_x(active) + view_offset`. Column widths are resolved from
`ColumnWidth::Proportion(p)` / `ColumnWidth::Fixed(px)` by
`Column::resolve_column_width` (line 4401). Scrolling is entirely the animated
`view_offset`.

### Chosen design

Add a `fit-columns` flag to the `layout {}` block. When enabled:

1. Every column stays visible; there is no horizontal scrolling.
2. The sum of column widths plus gaps always equals the working-area width.
3. Column widths are distributed proportionally to each column's configured
   weight (`Proportion(p)` -> `p`, `Fixed(px)` -> `px` relative to the working
   width), so resizing one column rebalances the others.
4. Adding a column shrinks the others; removing one grows them; a single column
   fills the width. This matches sway's manual-tiling feel while keeping niri's
   column/tab semantics, animations, and visuals.

### Config surface

`niri-config/src/layout.rs`:

- Add `pub fit_columns: bool` to `Layout` (line 11), default `false`.
- Add `pub fit_columns: Option<Flag>` to `LayoutPart` (line 98), following the
  `always_center_single_column` pattern.
- Add `fit_columns` to the `merge!` list in
  `impl MergeWith<LayoutPart> for Layout` (line 60).
- Because it lives in `LayoutPart`, it is automatically available as a global
  setting, per-output override, and per-named-workspace override.
- `resources/default-config.kdl` and `niri-config/tests/wiki-parses.rs` only
  need updates if we document the option; no existing parse test breaks.

### Core algorithm

Add intrinsic/desired width to the cached column data and a normalization pass
in `src/layout/scrolling.rs`:

```rust
struct ColumnData {
    /// Configured weight-derived width, before fit normalization.
    desired_width: f64,
    /// Final on-screen width used by every consumer.
    width: f64,
}

impl<W: LayoutElement> ScrollingSpace<W> {
    fn fit_columns(&mut self) {
        if !self.options.layout.fit_columns {
            return;
        }
        let n = self.columns.len();
        if n == 0 {
            return;
        }
        let gaps = self.options.layout.gaps;
        let total_gaps = gaps * (n - 1) as f64;
        let avail = (self.working_area.size.w - total_gaps).max(1.);
        let sum: f64 = self.data.iter().map(|d| d.desired_width).sum();
        if sum <= 0. {
            return;
        }
        for d in &mut self.data {
            d.width = avail * d.desired_width / sum;
        }
    }
}
```

`ColumnData::update` (line 3891) sets `desired_width = column.width()` and then
`fit_columns` derives `width`. `column_xs`, hit-testing, move offsets and resize
logic keep reading `data[i].width`, so they automatically see the fitted value.

### Disabling scrolling

When `fit_columns` is on:

- Make `view_pos()` (line 2294) and `target_view_pos()` (line 2298) return the
  left edge of the working area instead of `column_x(active) + view_offset` (for
  the default zero left strut this is `0`; verify against the render-element
  origin convention and handle non-zero `working_area.loc.x` for left struts).
- Short-circuit `animate_view_offset*`, `compute_new_view_offset_*`,
  `center_focused_column`, and the horizontal swipe/gesture paths so focus moves
  never translate the strip.
- Keep `columns_in_render_order` as-is; it only affects z-order, and positions
  still come from real indices.

### Call sites that must re-run `fit_columns()`

`data[i].width` is mutated in many places; every one that changes a column's
desired width, the column set, the working area, or tab-indicator extra size
must normalize afterwards:

- `update_config` (line 313) after the zip/update loop.
- column insert/remove (lines 987, 1181).
- `set_column_width` / `set_window_height` resize paths and `SizeChange`
  handling (lines ~4861-4910).
- columns added/removed to a column, and tabbed indicator size changes.
- `update_view_size` / working-area changes.

A robust alternative that avoids missed call sites: keep `data[i].width` as the
intrinsic value and expose a single `fn width_at(&self, idx) -> f64` that
applies the fit factor, then route the ~15 direct `data[idx].width` reads
through it. Slightly more churn, but no stale-value risk.

### Interactions to verify

- Fullscreen / maximize: already bypass column widths via `SizingMode`; must
  still work and must not be re-fitted.
- `always-center-single-column` and `center-focused-column "always"`: disable in
  fit mode (single columns already fill the width).
- Interactive resize (`Mod+R`): should change relative weights, not absolute
  pixels; clamp to a minimum so a column can't collapse to zero.
- Client minimum sizes: fitted widths can fall below a client's `min_size`.
  Decide between honoring min sizes (total may overflow, fall back to scroll) or
  letting the client clip. Recommend honoring min sizes with an overflow
  fallback.
- `insert-hint`, overview, workspace shadows, closing/opening animations: all
  read widths/positions, so they should follow for free, but need visual checks.
- Multi-monitor: fit is per-workspace/per-output because it lives in
  `Layout`/`LayoutPart`.

### Tests

- Unit tests in `src/layout/tests.rs`. There are already `LayoutPart` literals
  at lines 2985 and 3892 that will need the new field.
- Add cases: 1/2/3 columns with equal weights, unequal weights, with gaps and
  struts, after resize, after column insert/remove, with tabbed columns, and
  with fullscreen/maximize toggled.
- `niri validate` the config and run the existing layout snapshot tests.

## Delivery in this repo

Niri is consumed as `pkgs.niri` (`users/pvl/niri/default.nix`), so ship the
feature as a patch overlay, matching the existing compositor overlay pattern in
`overlays/sway.nix`:

1. Add `overlays/niri.nix` (or `overlays/niri/default.nix`) that overrides
   `niri` with `patches = [ ./niri/0001-fit-columns.patch ]`.
2. The patch must target the exact `v26.04` source; pin the source (like the
   sway overlay does) or keep the nixpkgs version pinned so the patch applies.
3. Enable it in `overlays/default.nix` only for the relevant hosts/session.
4. Update `users/pvl/niri/config.nix`: declare workspaces `1`..`10`, add the
   `focus-workspace` binds, and add `fit-columns` under `layout {}` (optionally
   per-output so the ultra-wide/external outputs keep the scrolling layout).

Staged approach:

- Stage 0: feature 1 config only, verify workspaces persist and switch.
- Stage 1: minimal patch that only normalizes widths (no scroll changes) to
  prove the fit math and interactions.
- Stage 2: disable view-offset animation/gestures and centering in fit mode.
- Stage 3: min-size handling, tests, overlay packaging.

## Alternatives considered

- **Config-only approximation:** use `preset-column-widths` plus manual
  resizing, or `default-column-display "tabbed"` to stack everything. Neither
  auto-fits; tabbed shows only one window. Rejected.
- **Userspace watcher over `niri msg`:** no action exists to set all column
  widths at once, focus churn is visible, and scrolling cannot be disabled.
  Rejected as fragile.
- **Upstreaming:** niri's design principles are explicitly scrollable tiling, so
  a fit mode is unlikely to be accepted upstream soon. A local patch is the
  pragmatic path; keep it small and rebase-friendly.

## Open questions

1. Exact option name and whether it should be a flag or an enum with explicit
   weighting/min-width knobs.
2. Behavior when fitted widths would be below client minimum sizes.
3. Whether fit mode should also become the default for specific outputs (laptop
   at 1.25) while external ultra-wides keep scrolling.
4. Whether to upstream the config knob at least, to reduce patch surface.

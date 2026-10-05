# Sway Fractional-Scale Blur vs Niri

Investigation into why sway is blurry at `scale 1.25` on Wayland-native clients
(e.g. Chrome) while niri is pixel-sharp on the same output/config.

## Symptom

`users/pvl/wm/outputs.nix` sets `BOE NE140QDM-NX7` to `scale = "1.25"` with
`scale_filter = "nearest"`. Under sway, Wayland-native Chrome (and other apps)
look blurry; under niri the same apps are sharp. Setting `scale_filter nearest`
does not help on sway.

## Root cause

Sway lays out and positions everything on the **integer logical pixel grid**. At
scale `S`, one logical pixel is `S` physical pixels, so for fractional `S` most
integer logical coordinates land on **fractional physical coordinates**. The
scene then rounds the destination box to whole physical pixels
(`wlr_scene.c: scale_box` / `scale_length`), so the composited surface
size/offset no longer matches the client buffer exactly. wlroots resamples the
buffer to compensate (`buffer_width / dst_physical != 1.0`), which blurs the
whole surface and gets worse toward the far edge of large windows. This is why
blur is position/size dependent (see sway #8994: "blurrier the closer to the
bottom").

Contributing factor: `sway/desktop/output.c: get_scale_filter()` **overrides the
user's `scale_filter` to `BILINEAR`** whenever `dst_width < buffer_width` in raw
numbers. For any client that renders at a buffer scale above 1 (i.e. every
fractional/HiDPI client, since `dst_width` is logical and `buffer_width` is
physical), sway forces linear filtering. So `scale_filter nearest` is ignored
for Chrome; `nearest` would only trade blur for aliasing anyway.

Chrome is not the problem: it supports `wp_fractional_scale_v1` by default
(`kWaylandFractionalScaleV1 = FEATURE_ENABLED_BY_DEFAULT` in
`ui/ozone/common/features.cc`) and renders at exactly 1.25 when the compositor
advertises it. Sway does advertise it (`wlr_fractional_scale_v1_notify_scale` in
`sway/tree/view.c`), so the failure is in sway's compositing/alignment, not in
the client's chosen scale.

### Why niri is sharp

niri was built with a "fractional-logical" layout. All layout metrics and tile
positions are snapped to the physical pixel grid, e.g.
`src/utils/mod.rs: round_logical_in_physical(scale, x) = (x * scale).round() / scale`
and `to_physical_precise_round()`. Surfaces therefore always land on integer
physical pixels, so the buffer is copied 1:1 (no resample) and stays crisp.

## Status / has sway fixed it?

- Sway advertises `wp_fractional_scale_v1` since 1.8 (2023) and rounds the scale
  to `N/120` (`sway/config/output.c`), but that only fixes the value sent to
  clients, not physical alignment.
- The real fix is **sway PR #8715 "container, transaction: align to fractional
  grid"** (adds `align_to_fractional(scale, v) = round(v*scale)/scale`
  throughout `sway/desktop/transaction.c` and `sway/tree/container.c`). It
  explicitly claims to fix #8131 and #8117 and "all of the blurrying problems".
- As of October 2026 that PR is **still open / unmerged**, and it depends on
  unmerged wlroots scene work (fractional/double scene coordinates,
  `pixman_region64f`). wlroots master still declares
  `wlr_scene_node_set_position(struct wlr_scene_node *, int x, int y)`.
- So no: sway 1.10, 1.11 and current master still have this. The pinned git
  build in `overlays/sway.nix` (sway `97c342f9`, June 2026) contains no
  `align_to_fractional` equivalent.
- Only partial wlroots-side cleanups landed in 2025/2026 (highest-output-scale
  client config, scaled-region rounding, clip fix, pixman bilinear fix); they do
  not fix the core grid misalignment.

## Practical mitigations

- Use an **integer** scale (1 or 2) and adjust font/UI sizes per app instead of
  fractional output scale. This is still what sway's own docs recommend.
- Or run that output under niri, which already does the physical-grid snapping.
- `scale_filter nearest` has no effect for fractional/HiDPI clients because of
  `get_scale_filter()`; it won't fix this.

## Why it is not merged yet

Investigated Oct 2026. It is not a rejected fix, it is a stalled, invasive,
multi-repo change with no maintainer approval.

1. **It is blocked on wlroots, not sway.** The blur is produced by wlroots'
   `wlr_scene` position-dependent scaling (`scale_length`). The real fix is
   wlroots MR !5071 "scene: use position independent scaling" (open since
   2025-05-15, updated 2026-09-01). It is a 12-commit series that changes the
   public `wlr_scene` API to fractional (double) positions/sizes, adds
   `wlr_fbox_*` helpers and fractional `pixman` region helpers, and bumps the
   minimum pixman to 0.46.2. Sway can only merge #8715 after that lands.
2. **It is a merge chain, not one PR.** wlroots MR !5208 "render/pass: accept
   fractional destination coordinates" (open, since 2025-12-08) and !5171
   "output: fix effective resolution calculation with ceil()" (open, since
   2025-10-10) are also unmerged prerequisites/companions.
3. **Long-standing problem with design churn.** wlroots issue #3139 "scene: use
   doubles for coordinates" is from Aug 2021; #3793 is from Jan 2024. Earlier
   attempts were closed in favour of the current one: wlroots !4994 ("render:
   fix blurriness caused by 1px texture/buffer size mismatches") and !5027
   ("scene: use fractional positions") were both closed 2025-05-15, and sway PR
   #8660 was closed 2025-05-15 in favour of #8715. Maintainers prefer the
   double-precision approach over the 1px band-aid, but it is far more invasive.
4. **Single-author effort, no review bandwidth.** sway #8715 and wlroots !5071
   are both authored solely by agorgl, who has force-pushed/rebase-churned #8715
   from 2025-05 to 2026-08. The only sway review comment is vyivel's 2025-06-20
   remark; requested reviewer kennylevinsen has not approved. Last #8715
   activity is 2026-08-08 and GitHub reports `mergeable_state: dirty` (conflicts
   with master), i.e. currently stale.
5. **Open edge cases make maintainers cautious.** Testers keep finding bugs at
   odd scales (1.14, 1.68, 2.68): gaps between borders and window content
   (precision loss needing `pixman_region64f_translatef`), a NULL-deref segfault
   in `arrange_workspace_tiling` on output hotplug / `kanshictl reload` when
   `ws->output == NULL` (fixed in the branch 2026-01), and some clients (e.g.
   ptyxis) still blurry only when tiled.
6. **Release/ABI timing.** Breaking `wlr_scene` API requires coordinated wlroots
   - sway releases, which maintainers tend to schedule at the start of a cycle.

Bottom line: no maintainer has rejected it, but it needs wlroots' breaking scene
change to land first, and that change has been open for over a year with only
one primary author and no approver.

## References

- sway #8131 "Blurry scaling for native wayland apps" (regression 1.8.1 -> 1.9)
- sway #8117 "1.5 fractional scale isn't crisp and clear with Qt6 applications"
- sway #8994 "Swaybar causes apps to appear slightly blurry ..." (2026)
- sway #9035 "Blurry title bar in Chromium ... crisp in niri under fractional
  scaling" (2026, still open, no comments)
- sway PR #8715 "container, transaction: align to fractional grid" (open)
- wlroots scene fixes: `8713ac72`, `602a00ec`, `dc7dba8b`, `c66a9107`

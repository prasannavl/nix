# pvl-a1 Sway Fractional Scale Blur

## Context

- `pvl-a1` uses Sway with the internal BOE panel at scale `1.25`.
- Shared output defaults lived only in `kanshi/config`, so Sway itself started
  without output scale declarations and picked them up only after the
  `kanshi.service` profile applied.

## Findings

- That launch order is harmless for simple topology changes, but it is a poor
  fit for fractional scale correctness.
- When Sway starts before the intended output scale is declared, early clients
  and XWayland can be initialized on the pre-kanshi scale path and then get
  rescaled later.
- The result is the kind of mild blur that looks like “almost right” 125%
  scaling rather than a gross resolution mismatch.
- This does not change the wlroots/XWayland limitation that some X11 clients
  still look softer than native Wayland clients on fractional scales, but it
  removes an avoidable source of extra blur introduced by session startup
  ordering.

## Decision

- Keep `kanshi` as the owner of output profile switching and monitor placement.
- Move monitor mode/scale/transform/adaptive-sync defaults into shared Nix data
  consumed by both `kanshi` and the Sway config.
- Sway now receives the same output defaults at compositor startup, while
  `kanshi` continues to decide which outputs are enabled and where they are
  placed.

## Follow-up

- If blur remains after this change, treat the remaining issue as XWayland
  fractional scaling rather than monitor configuration.
- Prefer Wayland-native backends for Electron, Firefox, Qt, SDL, and similar
  apps when available, because that solves blur at the actual client-rendering
  layer instead of forcing compositor-side bitmap scaling.

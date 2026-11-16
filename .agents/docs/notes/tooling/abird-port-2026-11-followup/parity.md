# Shared-tree parity after the follow-up port

Snapshot: nix `master` after `12244f6d1` compared with Abird `master`
`c735a7247`. Compared by type, literal symlink target, bytes and mode.

## Counts

| Tree        |    Equal |   Common |       % | Only nix | Only Abird |
| ----------- | -------: | -------: | ------: | -------: | ---------: |
| `lib/`      |      548 |      563 |     97% |       63 |         50 |
| `pkgs/`     |      488 |      505 |     97% |       55 |        483 |
| `tf/`       |       56 |       84 |     67% |        1 |          4 |
| `scripts/`  |       27 |       31 |     87% |       13 |          8 |
| `overlays/` |        2 |        4 |     50% |        7 |          1 |
| **Total**   | **1121** | **1187** | **94%** |  **139** |    **546** |

Previous audit: `lib/` 527/549, `pkgs/` 457/490 equal common paths. The
denominator grew with source-side additions, and Abird's reverse port replaced
several of its own variants with the destination's. Five paths that had been
`source-identical` at the previous snapshot and then moved ahead in Abird
(`lib/flake/service-module.nix`, `lib/services/ai/consumer.nix`,
`lib/services/ai/tests/consumer.nix`, `pkgs/ext/stalwart-server/default.nix`,
`pkgs/ext/stalwart-server/sources.nix`) are equal again.

## Remaining differences, by class

- **Local policy and identity.** `lib/hardware.nix`,
  `lib/installer/config/default.nix`, `lib/locale.nix`, `lib/network.nix`,
  `lib/nix.nix`, `lib/sudo.nix`, `lib/systemd.nix`, `lib/flake/repo-checks.nix`,
  `lib/services/nix-builder-gc-coordination/default.nix`,
  `lib/tests/default.nix` (local test set and Numtide cache assertions),
  `overlays/default.nix`, `overlays/unstable.nix`.
- **Child-flake workspace policy.** Eleven wrapper `flake.nix` files inject
  `rustWorkspaceDeps = false`; Abird keeps its product-workspace default-off
  choice instead.
- **Newer local pins.** `lib/ext/tailscale/sources.nix` and the Rust
  qualification lane (`lib/flake/rust/qualification/*`,
  `lib/flake/rust/tests/test_layout.py`, `scripts/qualification/rust/*`) follow
  this repository's patched-Cargo lane and pin policy.
- **Registration.** `pkgs/manifest.nix` (local packages versus Abird product
  exports) and `pkgs/README.md` (Abird documents its product trees).
- **Infrastructure state.** `tf/` account/zone/tunnel records, tfvars and
  variable interfaces, including the encrypted `secret_zones_*` channels and the
  required non-null DNS `zones`. `tf/tests/test_variables.py` is an adaptation
  of the ported test to those interfaces.
- **Abird-only surface.** 546 paths: `pkgs/srv`, `pkgs/web`, `pkgs/labs`,
  `pkgs/bots`, `pkgs/apps`, `pkgs/ext/codex-app-server`, queue tools,
  `abird-protocol`, `lib/ext` service packages with no local consumer,
  `lib/flake/tests/abird`, and Abird-specific `scripts/support` helpers. These
  are private product or unshared units, not transfer gaps.

No unclassified row: every remaining difference above is either local policy,
infrastructure state, or Abird-only product.

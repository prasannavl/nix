# Niri Fixed Workspaces 1-5

Records the sway-like fixed-workspace setup added to
`users/pvl/niri/config.nix`.

## Requirement

- Laptop only: named workspaces `1`..`5` are always present; everything past
  them is dynamic, starting with niri's unnamed workspace at index `6`.
- Laptop plus the `lg-uw3840` external: the same `1`..`5` live on the external,
  and the laptop (and any other secondary output) keeps niri's dynamic
  workspaces.

## How niri supports this

No patching is needed. Niri's named workspaces behave like sway's fixed
workspaces, and `open-on-output` plus the `original_output` bookkeeping moves
them with the intended "primary" monitor:

- `Workspace::new_with_config` (`src/layout/workspace.rs`) sets
  `original_output` to the `open-on-output` value when present.
- `ensure_named_workspace` (`src/layout/mod.rs`) creates each named workspace on
  the output matching `open-on-output`; when that output is absent it falls back
  to `primary_idx`.
- `add_output` (`src/layout/mod.rs`) moves workspaces whose `original_output`
  matches the newly connected output off the primary monitor onto it.
- `remove_output` (`src/layout/mod.rs`) appends the disconnected monitor's
  workspaces back onto the primary monitor.

Net effect: `workspace "N" { open-on-output "<external>" }` parks `N` on the
primary when the external is absent, moves it to the external when connected,
and returns it on disconnect. Outputs with no named workspaces keep dynamic
ones.

## Stock niri behavior (no named workspaces)

niri already moves workspaces on output changes, always via the primary monitor,
with no config involved:

- Disconnect: `remove_output` drops empty unnamed workspaces (`into_workspaces`)
  and appends the rest to the primary monitor (`append_workspaces`).
- Reconnect: `add_output` moves workspaces **from primary** whose
  `original_output` matches the new output, keeping only `has_windows_or_name`.
- Fresh monitor: `Monitor::new` always appends one empty workspace.
- Unnamed workspaces update `original_output` when a window is added; named ones
  do not, which is why named workspaces reliably return to their output.
- Primary = first-connected monitor (`primary_idx` only changes on removal;
  monitors are not name-sorted).

So the default is "return to the output you came from, else stay on primary".
Our `open-on-output` upgrades that to the one-element preference for the fixed
workspaces. Nothing selects from a list today.

### Lid handling (native)

niri handles the lid itself (`set_lid_closed`, fed by both libinput and logind).
`Tty::should_disable_laptop_panels` disconnects laptop panels when the lid is
closed **and** an external monitor is connected; the
`debug { keep-laptop-panel-on-when-lid-is-closed }` flag opts out. Their logind
`HandleLidSwitchDocked=ignore` keeps the session alive, so this handling is what
runs. With the internal panel disconnected, `remove_output` appends its
workspaces to the primary monitor, which is the external when it is the only one
left.

### Unpinned named workspaces

`Layout::new` creates config workspaces before any output connects
(`Workspace::new_with_config_no_outputs`), so without `open-on-output` their
`original_output` is the default/empty `OutputId` and never matches an output:

- The first connected output takes all of them. Outputs appearing together are
  connected in name order, so the internal panel (`BOE …` < `LG …`) wins and
  they start on the laptop even with the external connected.
- Connecting the external later moves nothing.
- Closing the lid (external connected) disables the internal panel, primary
  becomes the external, and the workspaces move there.
- Opening the lid moves nothing back: the empty `original_output` matches no
  output, so they stay on the external until it disconnects or they are moved
  manually. A manual move sets `original_output`.

### Bulk workspace moves (no built-in)

niri has no action that moves all workspaces to a monitor.
`move-workspace-to-monitor <output> [--reference <ws>]` moves exactly one
workspace (default: focused), and the `Mod+Ctrl+Alt+…` binds are the focused one
only.

Moving them all with one key means binding a script. CLI-only version:

```sh
niri msg action focus-monitor "$src"
n=$(niri msg --json workspaces | jq '[.[] | select(.output == $src)] | length')
for _ in $(seq 1 "$n"); do
  niri msg action focus-monitor "$src"
  niri msg action move-workspace-to-monitor "$dst" --reference 1
done
```

The `focus-monitor` before each move is required because CLI reference parsing
reads numbers as `Index`, and an Index reference resolves against the focused
monitor; moving index 1 repeatedly therefore always takes the source's next
workspace. Addressing by workspace name/id instead needs raw JSON IPC
(`{"MoveWorkspaceToMonitor":{"output":"…","reference":{"Id":…}}}`), which the
`niri msg` CLI cannot express.

## Config shape

```nix
fixedWorkspaceNumbers = lib.range 1 5;
fixedWorkspaces = lib.concatMapStringsSep "\n" (n:
  lib.concatStringsSep "\n" ([
      ''workspace "${toString n}" {''
    ]
    ++ map (o: "  open-on-output \"${o.name}\"") outputs.priorityOutputs
    ++ ["}"]))
fixedWorkspaceNumbers;
```

and binds: the packaged default already binds `Mod+1..9`, so `Mod+1..5` hit the
fixed workspaces and `Mod+6..9` hit niri's unnamed/dynamic tail (indices past
the workspace count clamp to the bottommost empty workspace). `Mod+0` /
`Mod+Shift+0` still target index `10`, which now clamps to that same bottommost
(deepest) workspace; `Mod+Shift+1..9` move the focused column by index.

## Gotchas

- Binds use **indices**, not names. In KDL `focus-workspace 1` decodes to
  `WorkspaceReferenceArg::Index` and `focus-workspace "1"` to `Name`. Index is
  resolved per active monitor (`Layout::find_workspace_by_ref`), so indices are
  only meaningful on the monitor that holds the fixed workspaces. Because the
  named workspaces are declared in order `1`..`5` (index `6` is niri's unnamed
  tail), the fixed monitor's indices line up with the names, which keeps the
  binds clean. On a secondary dynamic monitor, index `N` may not exist and the
  shortcut is a no-op.
- Keep the workspace declaration order `1`..`5`; reordering or inserting named
  workspaces shifts indices, and niri always appends an unnamed empty workspace
  (`docs/wiki/Workspaces.md`: "There's always one empty workspace at the end of
  every monitor").
- The packaged default config (`pkg-default.kdl`) already binds `Mod+1..9` to
  `focus-workspace 1..9`; the overlay adds `Mod+0`, which targets index `10` and
  therefore clamps to the bottommost (last) workspace. Niri replaces conflicting
  binds from later config files (`niri-config/src/lib.rs`, `binds` handling),
  which is also how the overlay overrides other base binds.
- The `priorityOutputs` entries are the `"<make> <model> <serial>"` form, which
  is what `open-on-output` matches (`OutputName::matches`). Using
  make/model/serial survives connector renames; `Unknown` is the wildcard for
  missing fields.
- `focus-at-startup` order in `outputRules` already puts `lg-uw3840` before
  `a1`, so when both are connected the external gets startup focus.

## Monitor-specific pinning (implemented)

`users/pvl/wm/outputs.nix` owns the role; the niri config carries no monitor
names:

```nix
# first connected entry wins, else niri primary
priorityOutputs = [ lg-uw3840 ];
```

`users/pvl/niri/config.nix` renders one `open-on-output` line per entry.

Semantics:

- Entry connected: workspaces park there; later hotplug follows via niri's
  `add_output` / `remove_output`.
- No entry connected: fall back to niri's internal primary (`primary_idx`).
- Empty list: workspaces are declared unpinned.
- Ordered list resolves first-connected-else-primary (see below).
- Per-host divergence: promote to `priorityOutputsByHost` keyed by `hostName`,
  matching the kanshi pattern. Options B/C/D were considered and dropped.

Revert safety: a single entry generates the same KDL as the pre-pin form, so
reverting `feat(niri): pin master for ordered output fallbacks` keeps the
`nixpkgs` 26.04 niri valid (verified with both binaries). A second entry needs
the pin.

### Priority-list output placement

Contract: `placement = first(list entry that is connected) else niri primary`.

Implemented **upstream** in PR #4618 (commit `9a35d377`, merged 2026-09-22,
after the v26.04 tag). Syntax is one `open-on-output` line per candidate,
evaluated in config order:

```kdl
workspace "1" {
    open-on-output "LG Electronics LG ULTRAWIDE 506NTQDDR844"
    open-on-output "DP-9"
}
```

Upstream mechanics:

- `Workspace::find_preferred_output` returns the first `original_outputs` entry
  whose output is connected.
- `add_output` moves a workspace to the new output only when it is the first
  connected preference, so two connected candidates cannot steal workspaces from
  each other.
- `remove_output` re-resolves every workspace of the removed output against the
  remaining monitors, so a lower-priority candidate takes over instead of always
  falling back to primary.
- `ensure_named_workspace` uses the first connected preference, else
  `primary_idx`.

Packaging in this repo: **niri master pin** (`overlays/niri.nix`), chosen
2026-10-05 to get the feature now instead of carrying a backport patch.

- `src = builtins.fetchTree { type = "github"; owner = "niri-wm"; repo =
  "niri"; rev = "ed22699d99462f61ab171472d3ea67e844ea580d"; narHash =
  "sha256-3BtIY8xxJHLai3/73kOqgSgcVmqpSKpz9uUstQYgfLk="; }`.
- `cargoHash` is baked when the package is evaluated and cannot be changed by
  `overrideAttrs`, so the overlay sets `cargoDeps` directly:
  `prev.rustPlatform.fetchCargoVendor { inherit src; pname = "niri"; version =
  "26.04"; hash = "sha256-vtTh+TG6TdX46QydGKaeo50u2qdQf3UkQ50EML+5H9c="; }`.
- Keep `version = "26.04"`: niri renders `26.4.0` as `26.04` (`utils::version`
  zero-pads MINOR and drops a zero PATCH), so the version check passes.
- Verified through the repo overlay list: drv
  `rc1idk7ffy3pq22nwr7bk2wszbjx4whv-niri-26.04` builds and 203/0 tests pass.
- Bump cost: rev + narHash + vendor hash. The pin carries 165 commits and a
  2027-line `Cargo.lock` delta relative to v26.04; revert to nixpkgs niri after
  the next release.

Related cleanup: `outputRules` in the same config also names `lg-uw3840` and
`a1` (per-output layout overrides). The same seam can absorb it with an
output-keyed policy table if the niri config should be fully monitor-agnostic.

## Validation

The generated config was validated with the pinned `niri 26.04` binary:

1. Evaluate `nix-config.kdl` from the module (with stub `config`/`pkgs`) and
   write it next to the base config.
2. `niri validate -c <dir>/config.kdl` with a wrapper that `include`s
   `base-config.kdl` then `nix-config.kdl`.

Note: concatenating base and overlay into one file is **not** a valid check.
Niri forbids duplicate top-level sections within one file but allows them across
`include`s.

## Related

- `.agents/docs/plans/niri-sway-like-layout-2026-10.md` covers the second,
  still-unimplemented feature (screen-constrained non-scrolling layout).

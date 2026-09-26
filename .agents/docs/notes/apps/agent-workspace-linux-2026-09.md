# agent-workspace-linux on pvl-a1 and pvl-l5

On 2026-09-26, `pvl-a1` and `pvl-l5` gained
[`agent-sh/agent-workspace-linux`](https://github.com/agent-sh/agent-workspace-linux),
an MCP server that gives an agent its own hidden X11 desktop instead of driving
the user's real session. The package is exported from the root flake and added
to both hosts' `environment.systemPackages`.

## Package unit

The upstream unit lives in `pkgs/ext/agent-workspace-linux/`:

- `sources.nix` pins the `v0.3.3` GitHub release and the x86_64/aarch64 asset
  hashes.
- `default.nix` installs the prebuilt release binary, patches it, and wraps it
  with its runtime tools.
- `update.sh` reports and updates the release version and both asset hashes, and
  participates in `scripts/update.sh` as the `agent-workspace-linux` unit.

The package is registered in `pkgs/manifest.nix`, so it is available as
`pkgs.agent-workspace-linux` (and `nix build .#agent-workspace-linux`) before
either host consumes it.

## Why the prebuilt release binary

Upstream's runtime links only `libxcb`, `libxkbcommon` (including its x11
module), `libgcc_s`, and glibc. Building from source would pull `gpui` and
`gpui_platform` from the zed `main` branch, which is a very heavy and
moving-target Rust build. The release workflow already publishes
`agent-workspace-linux-<target>` binaries plus `.sha256` sidecars for exactly
the two Linux targets this repo uses, so the unit installs those and uses
`autoPatchelfHook` for the dynamic loader and library paths.

## Runtime tools

The MCP server resolves helper commands through `PATH`. The wrapper prefixes the
runtime tools so the package is self-contained rather than depending on
host-wide installs:

- Xvfb, xauth, xdpyinfo, xprop, xwininfo
- openbox (window manager), xdotool (scoped input)
- xclip (clipboard), ImageMagick (`import` screenshots)
- bubblewrap (`bwrap` mount/network isolation), util-linux (`setsid` daemon)
- pkg-config, xdg-utils (`xdg-open`), bash (`sh`)

The wrapper also sets `PKG_CONFIG_PATH` to `libxkbcommon`'s dev output so
`agent-workspace-linux doctor` reports the viewer's `xkbcommon-x11` check as
ready. With those in place the local `doctor` run reports
`ready_for_x11_workspace: true` and no blockers.

## Boundaries

Home Manager/NixOS owns only the package and its runtime closure. It does not
manage the MCP host registration or the bundled skill
(`skills/agent-workspace-linux/SKILL.md`), matching the repo's treatment of
other agent-owned configuration such as Pi's `settings.json`. Register the
server per host, for example in an MCP host's config:

```json
{
  "mcpServers": {
    "agent-workspace-linux": {
      "command": "agent-workspace-linux",
      "args": ["mcp"]
    }
  }
}
```

The bundled skill can be copied from the upstream tag into the host's skills
directory when low-context tool loading is wanted.

## Validation

```console
nix build .#agent-workspace-linux --no-link --print-out-paths
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
agent-workspace-linux doctor
pkgs/ext/agent-workspace-linux/update.sh --report
```

`doctor` inside a live desktop session reports `ready_for_host_viewer: true` as
well; from a non-graphical shell the only viewer blocker is the missing
`DISPLAY`/`WAYLAND_DISPLAY`.

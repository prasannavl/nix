# Pi desktop MCP servers (Blender, GIMP, Computer Use, Obsidian, PowerPoint)

On 2026-11-01 the Pvl Home Manager `pi` profile gained five more MCP
declarations next to `playwright`, all fed to the same `pi-mcp-adapter` through
`~/.config/mcp/mcp.json`. Each server is packaged under an external unit root
and added to `home.packages` so its CLI is available for first-run setup.

## Units

All five units now follow upstream under `lib/ext/`.
`lib/overlays/agent-tools.nix` exposes them as `pkgs.*`;
`users/pvl/pi/default.nix` consumes those attributes. GIMP MCP and MCPVault no
longer have root flake package outputs. See
[external source units](../../design-patterns/external-source-units.md) for the
ownership rule.

| Unit under `lib/ext/`          | Build input                                      | How updates are found                                |
| ------------------------------ | ------------------------------------------------ | ---------------------------------------------------- |
| `computer-use-linux`           | GitHub binaries (3 per target)                   | Generic tag report                                   |
| `mcp-for-blender`              | PyPI sdist including the add-on                  | Generic `main` branch report; pin the matching sdist |
| `gimp-mcp`                     | GitHub release source at a fixed revision        | Generic `v` tag report                               |
| `mcpvault`                     | Exact npm release and its locked runtime closure | Executable `update.sh` reports and updates           |
| `office-powerpoint-mcp-server` | PyPI sdist                                       | Generic tag report                                   |

`scripts/update.sh --report --only-ext` discovers the units by filename, without
a central package list. For report-only units, update `sources.nix` and rebuild.
For MCPVault, use `lib/ext/mcpvault/update.sh --report` to inspect the candidate
or `--version VERSION` to regenerate the runtime manifest, lock and
`npmDepsHash` from the public npm release. An unchanged version is a no-op; add
`--force` to regenerate that pin. The updater builds the candidate against
locked Nixpkgs before replacing files; do not hand-edit the lock.

Separate from the GIMP MCP and MCPVault moves, upstream `ba0088db3` updates
Computer Use Linux `0.7.35 → 0.7.64` and `a5b532eca` updates MCP for Blender
`2.2.6 → 2.3.3`. Neither changes placement or Pi's graphical-host gate; see each
unit's `sources.nix` for the selected pin.

## Gating

`graphicalHost = !osConfig.boot.isContainer` keeps Blender, GIMP and Computer
Use on the graphical hosts (pvl-a1, pvl-l5, pvl-x2) and off the headless Incus
LXC profiles, because those three drive a live desktop session. Obsidian
(`mcpvault`), PowerPoint and Playwright only touch files or a headless browser,
so all three are declared on every profile, and `mcp.json` is written
unconditionally. The LXC profiles therefore carry Playwright's ~2.3 GiB browser
closure; see the Playwright note for the container sandbox caveat.

## Choice notes

- **Obsidian: `bitbonsai/mcpvault`.** Filesystem-based, so no Obsidian Local
  REST API plugin, API key, or running Obsidian is required; 18 tools including
  outline/line reads, BM25-ranked `search_notes`, frontmatter and tag
  management, and path checks that block traversal and dotfile access. The
  REST-API alternatives (`MarkusPfundstein/mcp-obsidian`,
  `cyanheads/obsidian-mcp-server`, and the Local REST API plugin's own MCP
  endpoint) need the plugin plus a stored API key and are only live while
  Obsidian is open. The vault path is `<home>/notes`, matching
  `~/.config/obsidian/obsidian.json`.
- **PowerPoint: the MCP server, not the `pi-powerpoint` skill.** The published
  `pi-powerpoint` skill is a generated CLI wrapper that spawns
  `uvx --from office-powerpoint-mcp-server ppt_mcp_server` through `mcporter`
  and therefore needs `bun`, `uv`, and a first-run network install. Declaring
  `office-powerpoint-mcp-server` directly gives Pi the same 37 tools under the
  MCP adapter without a runtime download.

## Package specifics

- `computer-use-linux` installs all three release binaries
  (`computer-use-linux`, `-cosmic`, `-indicator`) into one `$out/bin` so the
  server finds its helpers by adjacency, runs `autoPatchelfHook` for the glibc
  interpreter, and wraps the main binary with `PATH` entries for `xdotool`,
  `ydotool`, `wtype`, `gnome-screenshot`, `grim`, `notify-send` and `gsettings`
  plus `LD_LIBRARY_PATH` for the `dlopen`ed `libxkbcommon`.
- **GIMP MCP:** the November 1 snapshot needed a local FastMCP patch: SDK 1.10.1
  ignored `description`; newer 1.x SDKs rejected it. Release `v0.6.0` includes
  the fix and requires `mcp>=1.28.1,<2`. The recipe uses
  `unstable.python3Packages.mcp_1` and checks the `gimp_mcp_server` import. No
  local patch or standalone `fastmcp` dependency; license GPL-3.0-or-later.
- **MCPVault:** `0.18.3` paired the published app tarball with a separately
  maintained runtime closure: upstream's bun-generated lock lacked npm
  `resolved`/`integrity` entries. In `0.18.4`, which fixes absolute paths in
  symlinked vaults, `runtime/package.json` depends on the exact published app.
  One generated lock now covers the app and its dependencies. The package checks
  the locked app version against `sources.nix` and wraps the published
  `dist/server.js` with Node 22.

## User installation and updates (not managed by Home Manager)

- **Blender:** `mcp-for-blender install-addon` installs the bundled addon into
  `addon-paths` (currently `~/.config/blender/5.1/scripts/addons`); enable it
  and open its server panel in Blender. The bundled copy also sits at
  `$out/lib/python3.*/site-packages/blender_mcp/bundled/addon.py`.
- **GIMP:** use GIMP **3.2+**. Stable nixos-26.05 ships 3.0.8; installing the
  MCP package does not upgrade the desktop app. The locked alternative,
  `.#nixosConfigurations.pvl-x2.pkgs.unstable.gimp`, is 3.2.8. Launch the
  compatible GIMP once, check **Edit → Preferences → Folders → Plug-ins**, then
  close it. Run `gimp-mcp-server install-plugin --gimp-dir ~/.config/GIMP/3.2`
  from the selected MCP package, substituting the active config directory (the
  parent of `plug-ins`). Restart GIMP, open an image and choose **Tools → MCP →
  Start MCP Server** (default `localhost:9877`).
- **After a GIMP MCP update:** the server and plugin must match. Re-run the
  installer from the new profile, then restart GIMP and the MCP client. Also
  re-run it when a GIMP minor upgrade creates a new config directory. For a
  manual install, re-copy `$out/share/gimp-mcp/gimp-mcp-plugin.py` to
  `plug-ins/gimp-mcp-plugin/gimp-mcp-plugin.py` under the active config with
  mode `0755`. The store copy is `0644` to preserve `#!/usr/bin/env python3` for
  GIMP's Python; neither kind of user copy follows profile updates.
- **Computer Use:** `computer-use-linux doctor | jq .readiness`, then
  `computer-use-linux setup` (GNOME AT-SPI) and `setup-window-targeting` when
  the report asks for the GNOME Shell extension.

## Validation

Build the moved packages via the host overlay:

```console
nix build --no-link .#nixosConfigurations.pvl-x2.pkgs.gimp-mcp \
  .#nixosConfigurations.pvl-x2.pkgs.mcpvault
```

For runtime qualification, check `initialize` and `tools/list` over stdio. With
GIMP 3.2+ running the matching plugin, call `check_server`; import and stdio
checks alone do not exercise GIMP. For MCPVault, use a disposable vault and test
absolute-path read/write through a symlink, not the live notes tree.

**Historical evidence (November 1, before the migrations):** all five servers
completed a stdio `initialize` and `tools/list`. Computer Use exposed its
`computer_use` toolset, MCP for Blender its Blender tools, GIMP MCP **79**
tools, MCPVault its vault tools and PowerPoint its presentation tools. Blender
logged a connection refusal until its add-on server ran; GIMP MCP and MCPVault
connected lazily per call. These observations do not qualify the updated pins.

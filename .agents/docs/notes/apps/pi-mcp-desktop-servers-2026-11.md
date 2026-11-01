# Pi desktop MCP servers (Blender, GIMP, Computer Use, Obsidian, PowerPoint)

On 2026-11-01 the Pvl Home Manager `pi` profile gained five more MCP
declarations next to `playwright`, all fed to the same `pi-mcp-adapter` through
`~/.config/mcp/mcp.json`. Each server is packaged under an external unit root
and added to `home.packages` so its CLI is available for first-run setup.

## Units

| Package                              | Source                                         | Unit                                   |
| ------------------------------------ | ---------------------------------------------- | -------------------------------------- |
| `computer-use-linux` 0.7.35          | GitHub release binaries (3 per target)         | `lib/ext/computer-use-linux`           |
| `mcp-for-blender` 2.2.6              | PyPI sdist                                     | `lib/ext/mcp-for-blender`              |
| `gimp-mcp` unstable-2026-11-01       | GitHub source, patched                         | `pkgs/ext/gimp-mcp`                    |
| `mcpvault` 0.18.3                    | npm tarball + vendored runtime dependency lock | `pkgs/ext/mcpvault`                    |
| `office-powerpoint-mcp-server` 2.0.7 | PyPI sdist                                     | `lib/ext/office-powerpoint-mcp-server` |

The two `pkgs/ext` units are registered in `pkgs/manifest.nix` and build
standalone with `nix build .#<package>`. The three `lib/ext` units are exposed
as `pkgs.*` attributes by `overlays/agent-tools.nix`, which groups agent-facing
upstream tooling; the pi module and host package lists use those attributes
instead of repeating `pkgs.callPackage ../lib/ext/<unit>` at each call site.

## Placement

[External source units](../../design-patterns/external-source-units.md) splits
the roots by management style, and registration follows placement:

- `lib/ext/` — unit follows upstream. `computer-use-linux`, `mcp-for-blender`
  and `office-powerpoint-mcp-server` are unpatched upstream sources whose
  versions the generic reporter tracks by tag; nothing in the repository owns
  their shape. The pre-existing `bladebro` pi extension moved here in the same
  pass for the same reason (updater, no patches).
- `pkgs/ext/` — repository manages the unit. `gimp-mcp` carries a repo patch and
  `mcpvault` carries a vendored runtime dependency closure, so both stay
  manifest-registered with a repo-owned review cycle.

## Source reporting

None of the MCP units ships a package-local `update.sh`, so
`scripts/update.sh --report` routes each `sources.nix` to the generic read-only
reporter, which only understands `github-branch`, `github-tags`, `gitlab-tags`
and `registry-tags`. `kind` therefore names the reporting anchor, which is not
always the build input:

- `computer-use-linux`, `mcpvault`, `office-powerpoint-mcp-server` —
  `github-tags` against the upstream tag matching the pinned version; the build
  still uses release assets, the npm tarball, or the PyPI sdist.
- `gimp-mcp`, `mcp-for-blender` — `github-branch` on `main`, because neither
  upstream tags releases. `mcp-for-blender` builds the PyPI sdist published for
  that commit; `gimp-mcp` builds the pinned revision.

Version bumps stay manual: edit `sources.nix` (including hashes) and rebuild.
Adding a package-local updater later only replaces the `kind` anchor.

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
- `gimp-mcp` carries `fix-fastmcp-instructions.patch`: upstream calls
  `FastMCP("GimpMCP", description=...)`, but `description` has never been a
  FastMCP parameter (`instructions` is). It works for upstream only by accident
  — their `uv.lock` pins `mcp` 1.10.1, whose `FastMCP.__init__` ends in
  `**settings`, and `mcp.server.fastmcp.settings.Settings` is
  `SettingsConfigDict(..., extra="ignore")`, so the kwarg is silently dropped
  and the instructions never reach the server. Since `mcp` 1.12 the catch-all is
  gone (verified absent in 1.12.4, 1.13.0, 1.20.0, 1.26.0) and the same call
  raises `TypeError`. Upstream has not seen it because they never build against
  a newer SDK and the repo has no tags, so no CI pin moved. Pinning `mcp` 1.10.1
  here would also work but keeps a stale SDK; the one-line rename is the smaller
  fix and makes the instructions actually effective. Worth sending upstream. The
  GIMP-side plugin ships at `$out/share/gimp-mcp/gimp-mcp-plugin.py`.
- `mcpvault` ships a committed `dist/`, but its upstream bun-generated
  `package-lock.json` has 59 entries without `resolved`/`integrity`, so npm
  cannot install offline from it. `pkgs/ext/mcpvault/runtime/` pins only the
  manifest's runtime dependencies (a complete lock, 81 entries) and their
  closure is copied next to the unpacked tarball.
- Licenses: GIMP MCP ships a GPL-3.0 `LICENSE` despite an MIT `pyproject` field,
  so the package declares `gpl3Only`.

## First-run steps (not managed by Home Manager)

- **Blender:** `mcp-for-blender install-addon` installs the bundled addon into
  `addon-paths` (currently `~/.config/blender/5.1/scripts/addons`); enable it
  and open its server panel in Blender. The bundled copy also sits at
  `$out/lib/python3.*/site-packages/blender_mcp/bundled/addon.py`.
- **GIMP:** requires GIMP 3.2+, while `nixpkgs` (nixos-26.05) ships 3.0.8. Copy
  `$out/share/gimp-mcp/gimp-mcp-plugin.py` into the newest
  `~/.config/GIMP/<major.minor>/plug-ins/gimp-mcp-plugin/`, restart GIMP, and
  start `Tools > MCP > Start MCP Server` (port 9877). On 3.0.x the plugin is not
  expected to load.
- **Computer Use:** `computer-use-linux doctor | jq .readiness`, then
  `computer-use-linux setup` (GNOME AT-SPI) and `setup-window-targeting` when
  the report asks for the GNOME Shell extension.

## Validation

```console
nix build .#computer-use-linux .#mcp-for-blender .#gimp-mcp .#mcpvault \
  .#office-powerpoint-mcp-server
nix eval --raw .#nixosConfigurations.pvl-x2.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.pvl-vlab.config.system.build.toplevel.drvPath
```

Each server was driven through a stdio `initialize` + `tools/list` exchange:
Computer Use returns its `computer_use` toolset, `mcp-for-blender` its Blender
tools, `gimp-mcp-server` 79 tools, `mcpvault` the MCPVault tools, and
`ppt_mcp_server` the PowerPoint tools. `mcp-for-blender` logs a connection
refusal until Blender runs its addon server; `gimp-mcp` and `mcpvault` connect
lazily per call.

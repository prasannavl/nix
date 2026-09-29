# Pi MCP adapter and Playwright server

On 2026-09-29 the Pvl Home Manager profiles gained the `pi-mcp-adapter`
extension and a Playwright MCP server declaration. Pi has no built-in MCP
support in the pinned `pkgs.unstable.pi-coding-agent` 0.86.1, so MCP access
comes from `nicobailon/pi-mcp-adapter`. The adapter exposes one small proxy tool
and discovers server tools on demand instead of loading every server's tool
schemas into context.

## Package unit

The upstream unit lives in `lib/ext/pi/pi-mcp-adapter/` and is registered in
`lib/ext/pi/sources.nix` as `pi-mcp-adapter` 3.2.0:

- `default.nix` builds the published npm tarball with `buildNpmPackage`.
- `update.sh` gained `pi-mcp-adapter` in `ALL_PACKAGES` and reuses the `pi-web`
  hash path: npm-tarball `srcHash` plus GitHub-tag `releaseHash` for the
  lockfile, then `compute_npm_deps_hash`.
- `npmDepsFetcherVersion = 2` and `dontNpmBuild = true` match the other
  `lib/ext/pi` units.

The tarball ships the runtime TypeScript sources, the prebuilt `dist/` bundle,
and no lockfile. The build pairs it with the tagged upstream `package-lock.json`
and reconciles the manifest with Pi's extension model:

- Pi provides `@earendil-works/pi-ai`, `@earendil-works/pi-tui`,
  `@earendil-works/pi-coding-agent`, and `typebox` to TypeScript extensions at
  runtime, so the build drops them from `peerDependencies` and the lockfile.
  Their transitive `@earendil-works` lock entries carry a registry URL but no
  integrity hash, which `prefetch-npm-deps` rejects.
- The build drops `devDependencies` and the `prepack`/`prepare` scripts so the
  install hook does not run `tsc -p tsconfig.public.json` against a stripped
  dependency set.

The result is installed as `$out/lib/node_modules/pi-mcp-adapter`, which Pi
loads through `pi.extensions: ["./index.ts"]`. The CLI is available at
`$out/bin/pi-mcp-adapter` for `init` and credential commands.

## Playwright MCP server

`users/pvl/pi/default.nix` writes the adapter's shared user-global config to
`~/.config/mcp/mcp.json` and declares one server:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "<nixpkgs playwright-mcp>/bin/playwright-mcp",
      "args": ["--headless", "--isolated"]
    }
  }
}
```

The command uses the NixOS `playwright-mcp` package (0.0.69 in the pinned
nixpkgs), which is wrapped with `PLAYWRIGHT_BROWSERS_PATH` and a default
chromium browser, so the server does not download browsers at runtime. The
`--headless --isolated` flags match the nixpkgs maintainer's tested smoke-test
invocation. The shared MCP file is the adapter's documented user-global server
source; adapter-specific overrides such as `disabled` remain writable in
`~/.pi/agent/mcp-adapter.json`, which Home Manager does not manage.

The Playwright browser closure is about 2 GiB. The server declaration and the
`playwright-mcp` package are therefore gated on `!osConfig.boot.isContainer`, so
the graphical hosts (pvl-a1, pvl-l5, pvl-x2) get Playwright while the headless
Incus LXC profiles do not. Enable it on a container by removing that gate only
with a demonstrated need.

The module also links the adapter's `skills/mcp-scripting/SKILL.md` as
`~/.pi/agent/skills/mcp-scripting`. The skill is
`disable-model-invocation: true`, so it is opt-in rather than auto-loaded.

## Ownership

Home Manager owns the immutable extension tree
`~/.pi/agent/extensions/pi-mcp-adapter`, the `~/.config/mcp/mcp.json` server
declaration, and the `mcp-scripting` skill. It does not manage
`~/.pi/agent/mcp-adapter.json`, project `.pi/mcp-adapter.json`, server auth
state, or metadata caches, so the adapter can keep its own writable state.

## Validation

```console
nix-build lib/ext/pi/pi-mcp-adapter --no-out-link
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-vlab.config.system.build.toplevel.drvPath --raw
```

The extension-load check runs Pi in RPC mode with the built extension and issues
`get_commands`; a successful result includes `/mcp-adapter`, `/mcp-auth`, and
`/mcp`:

```console
EXT=$(nix-build lib/ext/pi/pi-mcp-adapter --no-out-link)/lib/node_modules/pi-mcp-adapter/index.ts
printf '{"id":"1","type":"get_commands"}\n' |
  pi --mode rpc --no-session --offline -e "$EXT"
```

The Playwright server itself was checked with a direct stdio MCP `initialize` +
`tools/list` exchange against
`$(nix-build '<nixpkgs>' -A playwright-mcp)/bin/playwright-mcp --headless --isolated`,
which returns 21 `browser_*` tools.

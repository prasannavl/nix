# Pi coding-agent extensions

On 2026-09-14, the Pvl Home Manager profiles gained declarative
`pi-models-discovery`, `pi-session-manager`, `pi-subagents`, and `pi-tps`
resources, plus the `pi-web` command. On 2026-09-26 they gained `pi-diff` and
`pi-codex-limit`; see `.agents/docs/notes/apps/pi-diff-2026-09.md` for the
`pi-diff` packaging decision. On 2026-09-29 they gained `pi-mcp-adapter` and a
Playwright MCP server; see
`.agents/docs/notes/apps/pi-mcp-adapter-playwright-2026-09.md`. On 2026-10-25
they gained `pi-processes` for managed background commands plus a batch of
reporting, memory and prompt-aid extensions: `pi-usage`, `pi-stamp`,
`pi-openai-toolkit`, `pi-total-recall`, and the JuiceSharp `rpiv-*` set
(`voice`, `todo`, `btw`, `advisor`). On 2026-10-27 they gained
`pi-anthropic-auth` and dropped `pi-codex-limit`, whose Codex usage footer
`pi-usage` now covers. They also gained six agent-workflow extensions: the
narumiruna `pi-tool`, `pi-goal` and `pi-notify`, and the brettinternet
`pi-wait`, `pi-loop` and `pi-until`. On 2026-10-27 `pi-processes` was replaced
by `pi-patty-bg-tasks`, which auto-backgrounds long `bash` calls instead of
requiring the agent to pick a separate tool. The installation does not take
ownership of Pi's writable `~/.pi/agent/settings.json`.

## Package layout

The Pi executable selection and resource installation are private implementation
details of the Pvl Pi module. External extension and web package pins live under
`lib/ext/pi/`, where the repository maintenance entrypoint can discover their
shared updater. `users/pvl/pi/default.nix` calls those derivations directly;
they are not exported from the root package manifest or injected into the global
package set.

The module installs `pkgs.unstable.pi-coding-agent` directly, keeping the Pi
version choice local instead of replacing `pkgs.pi-coding-agent` through the
shared unstable overlay. `lib/ext/` owns externally maintained overlay and
maintenance derivations, while `pkgs/ext/` remains appropriate for independently
exported root packages. If another consumer needs root package exports later,
promote the Pi derivations into `pkgs/` and register them in
`pkgs/manifest.nix`.

## Updates

`lib/ext/pi/sources.nix` is the single machine-maintained source of versions,
upstream revisions, source hashes, release hashes, and npm dependency hashes for
all twenty-three packages. The executable `lib/ext/pi/update.sh` participates in
the standard maintenance interface as the `pi` extension updater:

```console
scripts/update.sh --report --only-ext-pi
scripts/update.sh --only-ext-pi
lib/ext/pi/update.sh --package pi-web
```

The updater reads current npm metadata, resolves npm-published Git commits or
release archives as appropriate, re-resolves the runtime dependency closure of
every `depsResolver = "registry"` package (range -> highest published version ->
unpack hash), recomputes fixed-output hashes, and rebuilds each changed package
in a repository-local staging directory. Re-running it for an unchanged version
leaves `sources.nix` byte-identical. It replaces `sources.nix` only after every
requested package validates, so a failed update does not leave partially updated
pins. Use repeated `--package` flags for a subset, `--version` with one package
for an explicit version, or `--force` to recompute the current version.

## Ownership

Pi keeps mutable provider, model, UI, and changelog state in
`~/.pi/agent/settings.json`. Home Manager therefore owns only individual paths
under Pi's auto-discovered global resource directories:

- the immutable code children under
  `~/.pi/agent/extensions/pi-models-discovery/`
- `~/.pi/agent/extensions/pi-extensions-i18n`
- `~/.pi/agent/extensions/pi-diff`
- `~/.pi/agent/extensions/pi-mcp-adapter`
- `~/.pi/agent/extensions/pi-anthropic-auth`
- `~/.pi/agent/extensions/pi-patty-bg-tasks`
- `~/.pi/agent/extensions/pi-usage`
- `~/.pi/agent/extensions/pi-tool`
- `~/.pi/agent/extensions/pi-goal`
- `~/.pi/agent/extensions/pi-wait`
- `~/.pi/agent/extensions/pi-loop`
- `~/.pi/agent/extensions/pi-until`
- `~/.pi/agent/extensions/pi-notify`
- `~/.pi/agent/extensions/pi-stamp`
- `~/.pi/agent/extensions/pi-openai-toolkit`
- `~/.pi/agent/extensions/pi-total-recall`
- `~/.pi/agent/extensions/rpiv-voice`
- `~/.pi/agent/extensions/rpiv-todo`
- `~/.pi/agent/extensions/rpiv-btw`
- `~/.pi/agent/extensions/rpiv-advisor`
- `~/.pi/agent/extensions/pi-session-manager.ts`
- `~/.pi/agent/extensions/pi-tps.ts`
- `~/.pi/agent/extensions/pi-subagents`
- the packaged `pi-models-discovery`, `session-history` (from
  `pi-total-recall`), and `mcp-scripting` skills under `~/.pi/agent/skills`

`pi-models-discovery` writes its cache to
`~/.pi/agent/extensions/pi-models-discovery/cache.json`. Home Manager leaves the
containing directory user-owned and links only the upstream code, locale,
manifest, and dependency children into it. Its `models.json` and
`models.json.discovery-bak` files also remain writable.

The remaining extension files and companion resources are immutable Nix-store
links. The package build resolves the subagent skill's relative documentation
links to the pinned package documentation so they remain valid from the global
skill symlinks. Pi's settings, authentication, extension runtime configuration,
sessions, profiles, agents, and generated run state remain writable and
user-owned. `pi-session-manager` can rename and delete those user-owned sessions
through its interactive, confirmation-gated UI; Home Manager does not manage the
session files.

`pi-extensions-i18n` persists its locale at
`$PI_CODING_AGENT_DIR/extensions/pi-extensions-i18n/config.json`, inside the
read-only Nix-store tree, so the in-app `/config:language` save fails with
`EROFS`. Rather than making the tree writable, `lib/ext/pi/pi-models-discovery`
patches the vendored copy's `DEFAULT_LOCALE_PREFERENCE` to the
`i18nDefaultLocale` build argument, which the Pvl Pi module sets to `en-US`.
`pi-models-discovery` imports the same vendored copy, so both it and the locale
command use the pinned default. The `substituteInPlace` guard fails the build if
a package update moves that declaration. Because the default is pinned in the
package, the in-app switcher is not used: change the locale by editing
`i18nDefaultLocale`.

Audit of the other managed extensions: none write inside their store tree.
`pi-models-discovery` writes `models.json` plus `cache.json` under the
user-owned `pi-models-discovery` directory, `pi-tps` writes
`~/.pi/agent/pi-tps.json`, `pi-session-manager` mutates user-owned session
files, and `pi-subagents` writes user-owned agent definitions and run state. The
2026-10-25 batch writes only outside its store trees too: `pi-usage` keeps its
settings next to `getAgentDir()`. `pi-total-recall` keeps
`~/.pi/memory/memory.db` plus its session and knowledge indexes under the user's
`~/.pi` tree, and the `rpiv-*` configs resolve through
`$XDG_CONFIG_HOME/<package>/config.json` (`~/.config/...` by default, never
inside the package). `rpiv-voice` downloads its STT model on demand and logs
failures under `$TMPDIR`. Only `pi-extensions-i18n` needed the locale
workaround.

## Packaging and compatibility

The local `pi-tps` derivation pins upstream version 1.0.1. That release still
imports the old `@mariozechner` Pi package names, so its Nix build performs the
narrow import rename to the current `@earendil-works` names.

The local `pi-subagents` derivation packages `@gotgenes/pi-subagents` 21.8.0
from its published npm tarball. Pi virtualizes the extension runtime imports
(`@earendil-works/*`, `@sinclair/typebox`), so the derivation fetches no npm
dependencies, and it adds a root `index.ts` re-export because the published
manifest points at `src/index.ts`. The extension ships no skill or prompt
resources. The Pvl Pi module keeps installing `pkgs.unstable.pi-coding-agent`;
gotgenes 21.8.0 declares `@earendil-works/pi-coding-agent >=0.81.0`. See
`.agents/docs/notes/apps/pi-subagents-gotgenes-switch-2026-09.md` for the switch
rationale, the pi-web coexistence behavior, and the removed assets.

The local `pi-models-discovery` derivation pins version 1.2.0 at the
npm-published monorepo commit. It installs the matching `pi-extensions-i18n`
0.5.0 workspace package as the extension's local runtime dependency.

The local `pi-session-manager` derivation packages the unscoped package from
`vahidkowsari/pi-session-manager`, pinned at version 0.1.0. It is distinct from
the larger similarly named desktop application. Like `pi-tps`, its published
source uses the old `@mariozechner` Pi import names, so the Nix build applies
only the current-package rename.

The local `pi-web` derivation packages `@agegr/pi-web` 0.9.1. The build uses the
exact prebuilt npm release payload and the corresponding tagged lockfile to
construct its runtime dependency closure reproducibly. Home Manager adds its
`pi-web` command to the Pvl profile but does not declare or start a service. The
command retains upstream's loopback-only default listener.

The local `pi-diff` derivation packages `@heyhuynhgiabuu/pi-diff` 0.9.1 from its
tagged source tree. It loads `src/index.ts` through Pi rather than the published
`dist/` bundle, drops the `@earendil-works` core packages and dev dependencies
from the upstream manifest, and caches only the `@shikijs/cli`, `diff`, and
`xxhash-wasm` runtime closure. See `.agents/docs/notes/apps/pi-diff-2026-09.md`
for the full rationale.

The local `pi-tool` and `pi-goal` derivations package `@narumitw/pi-tool` 0.4.0
and `@narumitw/pi-goal` 0.54.13 from the narumiruna monorepo. Each loads its
`dist/` bundle and pins `@narumitw/pi-tui-kit` separately (`^0.60.0` -> 0.60.0
and `^0.59.0` -> 0.59.0), because `deps` are nested per consumer. `pi-tool`
registers `/tool`, `pi-goal` registers `/goal`; both keep settings in the
user-owned agent directory.

The local `pi-notify` derivation packages `@narumitw/pi-notify` 0.4.1 from the
same monorepo, pinning `@narumitw/pi-tui-kit` `^0.65.6` (0.65.6). It registers
`/notify` and keeps `pi-notify.json` in the user-owned agent directory.

The local `pi-wait`, `pi-loop` and `pi-until` derivations package the
brettinternet extensions: unscoped `pi-wait` 0.1.5, `@brettinternet/pi-loop`
0.1.8, and unscoped `pi-until` 0.1.5. All three unscoped-free names are
published by the same npm maintainer, and the unscoped `pi-loop` on the registry
belongs to a different author (`jnyross`, no `pi` manifest), which is why the
scoped name is pinned. The first two are pure TypeScript with no runtime
dependencies; `pi-until` pins `xstate` 5.33.2 through `depsResolver`. They
register the `/loop` and `/until` commands, and `pi-wait` contributes the
`wait_then_continue` and `cancel_wait` tools rather than a command. `pi-loop`
keeps no writable state, and `pi-until` writes telemetry under
`~/.pi/agent/pi-until/`.

The local `pi-mcp-adapter` derivation packages `pi-mcp-adapter` 3.2.0 from its
npm tarball plus the tagged upstream lockfile. The build drops the
Pi-virtualized peer/dev packages and the `prepack`/`prepare` scripts, then
caches only the runtime closure. See
`.agents/docs/notes/apps/pi-mcp-adapter-playwright-2026-09.md` for the MCP
server declaration and the container gating.

The local `pi-patty-bg-tasks` derivation packages `pi-patty-bg-tasks` 1.1.6 from
its npm tarball. It has no runtime dependencies, so the derivation copies the
tarball unchanged and relies on Pi for the `@earendil-works/*` peers. Unlike
`pi-processes` it overrides the built-in `bash` tool: foreground calls
auto-background after 120 seconds, `run_in_background` or Ctrl+B background one
immediately, and the extension adds `bash_bg`, `jobs`, `job_decide`, `agent_bg`
and `monitor` plus the `/bg`, `/bg-list` and `/bg-version` commands. Job logs
are file-backed under `/tmp/pi-bg/<id>.log`, capped at 100 MB, and the 16-job
cap, stall threshold and timeouts are hard-coded rather than configurable. It
ships no skill and no settings file; nothing is written inside the store tree.

Each derivation stays self-contained: it unpacks its pinned tarball into
`$out/share/pi/packages/<pname>` and copies the runtime dependencies recorded in
`sources.nix` into the package's own `node_modules` through one generic loop. Pi
supplies `@earendil-works/*`, `typebox` and node builtins to extensions, and
those are never pinned.

Runtime dependencies are data, not derivation code. A package opts in with
`depsResolver = "registry";`; `lib/ext/pi/update.sh` then walks that release's
published dependency graph (its `dependencies` plus the `optionalDependencies`
that match the build platform), resolves the highest published version for each
declared range, and writes a sorted `deps` block into the package's
`sources.nix` entry. Every entry uses the same record shape as a package, marked
as a dependency:

```nix
deps = {
  "@narumitw/pi-tui-kit" = {
    kind = "npm-dep";
    range = "^0.66.0";   # declared requirement
    version = "0.66.0";  # resolved release
    srcHash = "sha256-…";
  };
};
```

`pi-stamp` pins the same package at `^0.59.0`, and because `deps` are nested per
consumer the two resolutions coexist. Platform selection for optional native
packages uses their `os`/`cpu` metadata, falling back to platform tokens in the
name (`-linux-x64`, `-darwin-arm64`, …) for prebuilds that declare neither —
that is how `rpiv-voice` gets `decibri`/`sherpa-onnx-node` plus exactly its
Linux x64 prebuilds. Packages without the marker keep their own scheme:
`pi-openai-toolkit` has no dependencies, `pi-total-recall` ships its closure
inside the tarball (`bundleDependencies`), and
`pi-web`/`pi-diff`/`pi-mcp-adapter` keep their lockfile-based `npmDepsHash`
builds.

The rest of the 2026-10-25 additions:

- `pi-usage` (`@narumitw/pi-usage`): the published `dist/` bundle keeps its
  `@narumitw/pi-tui-kit` import, so the resolver pins the kit 0.66.0 plus its
  declared `diff`, `grok-mermaid` and `highlight.js` dependencies.
- `pi-stamp` (`@narumitw/pi-stamp`): same monorepo, but it declares `pi-tui-kit`
  `^0.59.0`, so the resolver records that older kit beside pi-usage's 0.66.0
  instead of collapsing the two.
- `pi-openai-toolkit` (`pi-openai-toolkit`): pure TypeScript, no runtime
  dependencies; its manifest registers six extensions (runtime, web search,
  image generation, Codex fast/Astra, responses websocket).
- `pi-anthropic-auth` (`@gotgenes/pi-anthropic-auth`): pure TypeScript under
  `src/`, no runtime dependencies beyond the `@earendil-works` peers, so it is a
  plain tarball copy with no `depsResolver`; it registers the
  `anthropic-auth:status` command.
- `pi-total-recall` (`pi-total-recall`): the tarball bundles its three runtime
  packages (`@samfp/pi-memory`, `pi-session-search`, `pi-knowledge-search`)
  through `bundleDependencies`, and its `pi` manifest points both the three
  extensions and the `session-history` skill at those bundled copies, so the
  derivation copies the tarball unchanged. The module links `session-history` as
  a separate skill.
- `rpiv-*` (`@juicesharp/rpiv-mono`): one derivation per extension, each pinning
  `rpiv-config` inline; that is the only hard dependency. The declared
  `@juicesharp/rpiv-i18n` peer stays uninstalled on purpose because the
  extensions dynamic-import it and fall back to bundled English strings. Configs
  resolve through `$XDG_CONFIG_HOME/<package>/config.json`.
- `rpiv-voice` additionally needs decibri (microphone capture) and
  sherpa-onnx-node (local STT); the resolver adds their platform-matching
  prebuilds automatically. The derivation is `x86_64-linux`-only, runs
  `autoPatchelfHook` with `gcc`/`glibc` and `alsa-lib` so the `.node` addons and
  the bundled ONNX Runtime load from the store, and the extension downloads its
  STT model on first use.

All sources are content-addressed and version-pinned. Pi does not download or
update these packages at startup; normal Nix source and dependency hashes
control upgrades.

## Validation

Build all external Pi packages and evaluate the affected Home Manager profiles:

```console
nix-build lib/ext/pi/pi-models-discovery --no-out-link
nix-build lib/ext/pi/pi-session-manager --no-out-link
nix-build lib/ext/pi/pi-subagents --no-out-link
nix-build lib/ext/pi/pi-tps --no-out-link
nix-build lib/ext/pi/pi-web --no-out-link
nix-build lib/ext/pi/pi-diff --no-out-link
nix-build lib/ext/pi/pi-mcp-adapter --no-out-link
nix-build lib/ext/pi/pi-patty-bg-tasks --no-out-link
nix-build lib/ext/pi/pi-usage --no-out-link
nix-build lib/ext/pi/pi-tool --no-out-link
nix-build lib/ext/pi/pi-goal --no-out-link
nix-build lib/ext/pi/pi-wait --no-out-link
nix-build lib/ext/pi/pi-loop --no-out-link
nix-build lib/ext/pi/pi-until --no-out-link
nix-build lib/ext/pi/pi-notify --no-out-link
nix-build lib/ext/pi/pi-stamp --no-out-link
nix-build lib/ext/pi/pi-anthropic-auth --no-out-link
nix-build lib/ext/pi/pi-openai-toolkit --no-out-link
nix-build lib/ext/pi/pi-total-recall --no-out-link
nix-build lib/ext/pi/rpiv-voice --no-out-link
nix-build lib/ext/pi/rpiv-todo --no-out-link
nix-build lib/ext/pi/rpiv-btw --no-out-link
nix-build lib/ext/pi/rpiv-advisor --no-out-link
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-x2.config.system.build.toplevel.drvPath --raw
```

For an extension-load smoke test, run Pi in RPC mode with the generated Home
Manager resource layout and issue `get_commands`. A successful result includes
`/config:model-discovery`, `/config:language`, `/sessions`, `/sall`, `/pi-tps`,
and the `pi-subagents` commands (`/subagents:settings`, `/subagents:sessions`),
plus the `pi-mcp-adapter` commands (`/mcp-adapter`, `/mcp-auth`, `/mcp`); after
the gotgenes switch the six prompt templates and the
`pi-subagents`/`council-mode` skills are no longer installed.
`pi-patty-bg-tasks` adds the `bash_bg`, `jobs`, `job_decide`, `agent_bg` and
`monitor` tools, the `/bg`, `/bg-list`, `/bg-version` commands, and the `bash`
tool override. Validate the standalone UI command with `pi-web --help`; this
does not start a listener.

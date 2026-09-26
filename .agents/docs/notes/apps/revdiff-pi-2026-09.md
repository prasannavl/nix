# revdiff and Pi Diff extensions

On 2026-09-26, the Pvl Pi setup gained two external review extensions: `revdiff`
(a standalone Go TUI plus its Pi integration) and Pi Diff
(`@heyhuynhgiabuu/pi-diff`). Both are content-pinned and installed through Home
Manager; neither takes ownership of Pi's writable `settings.json`.

## revdiff

`umputun/revdiff` ships a Go diff-review TUI together with a Pi package under
`plugins/pi/`. The upstream unit lives in `lib/ext/revdiff/`:

- `sources.nix` pins the `v1.13.0` revision, the unpacked archive hash, and the
  packaged Pi extension version.
- `default.nix` builds the `revdiff` binary. The `app/` main package is renamed
  to `revdiff` at the pinned revision.
- `pi.nix` installs the Pi package: the upstream `plugins/pi` extension, script,
  and skill tree plus a generated `package.json`.
- `update.sh` reports and updates the revision, hash, and packaged extension
  version, and participates in `scripts/update.sh` as the `revdiff` unit.

The unit owns one upstream source, so the binary and the Pi package pin together
and the updater replaces only its sibling `sources.nix`.

The Pi module consumes the unit directly:

```nix
revdiff = pkgs.callPackage ../../../lib/ext/revdiff {};
revdiffPi = pkgs.callPackage ../../../lib/ext/revdiff/pi.nix {};
```

- `revdiff` is added to `home.packages`; the extension resolves it from `PATH`.
- `${revdiffPi}/share/pi/packages/revdiff-pi` is linked as
  `~/.pi/agent/extensions/pi-revdiff`.
- `plugins/pi/skills/revdiff` is linked as `~/.pi/agent/skills/revdiff`.

Pi's global extension auto-discovery does not expand a package manifest entry
that points at a directory, and the module loader cannot import a bare
directory. The installed `package.json` therefore points `pi.extensions` at
`./plugins/pi/extensions/revdiff.ts` directly. Keeping the upstream `plugins/pi`
layout also preserves the extension's relative lookup of
`../scripts/detect-ref.sh`.

Update and report through the standard maintenance interface:

```console
scripts/update.sh --report --only-ext-revdiff
scripts/update.sh --only-ext-revdiff
lib/ext/revdiff/update.sh --version 1.13.0
```

## Pi Diff

Pi Diff is npm package `@heyhuynhgiabuu/pi-diff` from
`buddingnewinsights/pi-diff`. It joins the existing `lib/ext/pi` suite:
`pi-diff` is added to `ALL_PACKAGES` and to `sources.nix`, and the suite updater
gained a package branch that pins the tagged source archive and `npmDepsHash`.

The derivation builds from the tagged source tree rather than the published npm
`dist/` bundle. Pi loads the TypeScript source directly, which matters because
the compiled `.js` bundle dynamically imports `@earendil-works/pi-coding-agent`
and `@earendil-works/pi-tui` with native ESM. Native dynamic import bypasses
Pi's jiti aliases, so the prebuilt bundle would need its own full copy of the Pi
SDK in `node_modules`. Loading `src/index.ts` lets Pi's virtual modules provide
the core packages instead.

The build reconciles the upstream manifest with Pi's extension model before
fetching dependencies:

- remove the `@earendil-works` core packages from `dependencies`, because Pi
  provides them at runtime;
- point `pi.extensions` at `./src/index.ts` and add `src/` to `files`;
- drop `devDependencies`.

Removing the core packages also removes bundled lockfile entries that carry a
registry URL but no integrity hash, which `prefetch-npm-deps` rejects. The
remaining runtime closure (`@shikijs/cli`, `diff`, `xxhash-wasm`) is cached from
the sanitized lockfile.

The Pi module links the package root as `~/.pi/agent/extensions/pi-diff`; no
separate skill is installed.

## Validation

Build every external Pi package and the revdiff unit, then evaluate the affected
Home Manager profiles:

```console
nix-build lib/ext/pi/pi-diff --no-out-link
nix-build lib/ext/revdiff --no-out-link
nix-build lib/ext/revdiff/pi.nix --no-out-link
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-x2.config.system.build.toplevel.drvPath --raw
```

For an extension-load smoke test, point `PI_CODING_AGENT_DIR` at a directory
that mirrors the Home Manager resource layout and issue `get_commands` over RPC
mode. A successful result includes the `/revdiff` command, the `skill:revdiff`
skill, and no `[pi-diff] failed to load Pi SDK dependencies` message on stderr.

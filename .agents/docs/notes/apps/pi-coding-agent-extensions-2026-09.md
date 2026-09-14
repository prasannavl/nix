# Pi coding-agent extensions

On 2026-09-14, the Pvl Home Manager profiles gained declarative
`pi-models-discovery`, `pi-session-manager`, `pi-subagents`, and `pi-tps`
resources, plus the `pi-web` command. The installation does not take ownership
of Pi's writable `~/.pi/agent/settings.json`.

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
all five packages. The executable `lib/ext/pi/update.sh` participates in the
standard maintenance interface as the `pi` extension updater:

```console
scripts/update.sh --report --only-ext-pi
scripts/update.sh --only-ext-pi
lib/ext/pi/update.sh --package pi-web
```

The updater reads current npm metadata, resolves npm-published Git commits or
release archives as appropriate, recomputes fixed-output hashes, and rebuilds
each changed package in a repository-local staging directory. It replaces
`sources.nix` only after every requested package validates, so a failed update
does not leave partially updated pins. Use repeated `--package` flags for a
subset, `--version` with one package for an explicit version, or `--force` to
recompute the current version.

## Ownership

Pi keeps mutable provider, model, UI, and changelog state in
`~/.pi/agent/settings.json`. Home Manager therefore owns only individual paths
under Pi's auto-discovered global resource directories:

- the immutable code children under
  `~/.pi/agent/extensions/pi-models-discovery/`
- `~/.pi/agent/extensions/pi-extensions-i18n`
- `~/.pi/agent/extensions/pi-session-manager.ts`
- `~/.pi/agent/extensions/pi-tps.ts`
- `~/.pi/agent/extensions/pi-subagents`
- the packaged `pi-models-discovery` skill under `~/.pi/agent/skills`
- the two packaged `pi-subagents` skills under `~/.pi/agent/skills`
- the packaged `pi-subagents` prompt templates under `~/.pi/agent/prompts`

`pi-models-discovery` writes its cache to
`~/.pi/agent/extensions/pi-models-discovery/cache.json`. Home Manager leaves the
containing directory user-owned and links only the upstream code, locale,
manifest, and dependency children into it. Its `models.json` and
`models.json.discovery-bak` files also remain writable.

The other extension trees and companion resources are immutable Nix-store links.
The package build resolves the subagent skill's relative documentation links to
the pinned package documentation so they remain valid from the global skill
symlinks. Pi's settings, authentication, extension runtime configuration,
sessions, profiles, agents, and generated run state remain writable and
user-owned. `pi-session-manager` can rename and delete those user-owned sessions
through its interactive, confirmation-gated UI; Home Manager does not manage the
session files.

## Packaging and compatibility

The local `pi-tps` derivation pins upstream version 1.0.1. That release still
imports the old `@mariozechner` Pi package names, so its Nix build performs the
narrow import rename to the current `@earendil-works` names.

The local `pi-subagents` derivation pins upstream version 0.67.0 and builds its
npm runtime dependency closure in Nix. The release requires Pi 0.80 or newer and
specifically supports Pi 0.85.1, so the Pvl Pi module installs
`pkgs.unstable.pi-coding-agent` instead of the older stable package.

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
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-x2.config.system.build.toplevel.drvPath --raw
```

For an extension-load smoke test, run Pi 0.85.1 in RPC mode with the generated
Home Manager resource layout and issue `get_commands`. A successful result
includes `/config:model-discovery`, `/config:language`, `/sessions`, `/sall`,
`/pi-tps`, the `subagents-*` commands, all six prompt templates, and all three
installed skills. Validate the standalone UI command with `pi-web --help`; this
does not start a listener.

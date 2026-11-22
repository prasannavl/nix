# Bladebro, Herdr, and Pi Web on pvl-a1

On 2026-10-11 the Pvl profiles gained two agent-runtime tools and pvl-a1 gained
the Pi Web UI. This note records the package boundary, the Pi extension wiring,
and the validation used.

## Scope

- `herdr` (the `herdrdev/herdr` terminal workspace manager for coding agents)
  installed on pvl-a1 and pvl-l5.
- `bladebro` (the `dondai44423/bladebro` stealth agentic browser driver) with
  its Pi agent extension, installed on pvl-a1 and pvl-l5.
- `pi-web` enabled on pvl-a1, mirroring the existing pvl-l5 service and exposed
  on the Tailscale interface only.

## Herdr

nixos-26.05 does not ship Herdr, but the pinned `nixos-unstable` input does.
`hosts/pvl-a1/packages.nix` and `hosts/pvl-l5/packages.nix` consume three
unstable attributes directly:

- `unstable.herdr` 0.9.5: the TUI/server (`herdr`).
- `unstable.herdr-core` 0.1.18: the core runtime and `hc` CLI.
- `unstable.herdr-desktop` 0.1.13: the native GPUI app (`herdr-app`).

No repository-local unit, source pin, or updater is needed; the unstable overlay
keeps owning the versions. The TUI package also installs every agent integration
source under `$out/share/herdr/integrations/`, so the Pi wiring below needs no
runtime `herdr integration install` step.

The app and the TUI are separate runtimes: the app drives `herdr-core`, while
`unstable.herdr` runs its own server. They can run side by side, but their panes
are not shared. The app needs a desktop session and a working Vulkan driver.

## Herdr Pi integration

`users/pvl/pi/default.nix` links `.pi/agent/extensions/herdr-agent-state.ts` to
`${pkgs.unstable.herdr}/share/herdr/integrations/pi/herdr-agent-state.ts` on the
hosts listed in `herdrHosts` (`pvl-a1`, `pvl-l5`). The extension is inert unless
the TUI server sets `HERDR_ENV=1` and provides its socket and pane id, so the
shared Pi profile keeps working outside Herdr. Inside a Herdr TUI pane it
reports `working`, `blocked` and `idle` state plus the Pi session path, which
lets the TUI restore the same session after a server restart.

This extension does not serve the app: `herdr-core` consumes Pi's native OSC
7501 status reports instead. The app therefore shows Pi state but does not
restore Pi sessions after a core restart.

Do not run `herdr integration install pi` on those hosts: it writes the same
path and would replace the Home Manager symlink. Bump `herdrHosts` when another
host starts installing `unstable.herdr`.

## Running it

Neither frontend has a browser client.

- TUI on pvl-a1: `ssh pvl-a1` then `herdr` (tmux-style; detach with `ctrl+b q`).
- TUI from another workstation: `herdr --remote pvl-a1`; panes run on pvl-a1 and
  the UI renders locally.
- Native app: launch Herdr from the app launcher or run `herdr-app`. `hc` from
  `herdr-core` is on `PATH`; add pvl-a1 under Settings -> Machines to keep
  remote spaces in the same window.
- Phone app: connects to `herdr-core`, not the TUI server. It sees app/core
  spaces only.

Browser access to Pi is the existing pvl-a1 `pi-web` service on port 30141, not
Herdr.

## Bladebro package unit

`bladebro` is absent from both nixpkgs channels, so it is a new independently
external package under `lib/ext/bladebro/`: it ships its own updater and carries
no repo-owned patch, so it follows upstream rather than being managed here. It
is not manifest-registered; the pi module consumes it directly.

The npm package is unusual in three ways that shape the unit:

- The published manifest declares no regular dependencies. The runtime
  dependency is the platform payload `bladebro-<os>-<arch>`, declared only as an
  optional dependency.
- The Pi extension resolves that payload at runtime with
  `require.resolve("<platform-package>/package.json")`, so the payload must live
  in a `node_modules` directory beside `pi-extension.ts`.
- The payload is a glibc-linked Rust binary whose interpreter is the non-Nix
  `/lib64/ld-linux-x86-64.so.2`.

`default.nix` therefore fetches the extension tarball and the matching platform
payload tarball directly, installs the payload as
`share/pi/packages/bladebro/node_modules/<platform-package>/`, runs
`autoPatchelfHook` (with `stdenv.cc.cc.lib`) to repair the interpreter, and
wraps the `bin.js` CLI on the pinned Node runtime. npm's optional-dependency
resolution is never invoked, so the store stays platform-exact. The extension
tree lives at the same `share/pi/packages/` layout the `lib/ext/pi` packages
use.

The Pi extension imports only Pi virtual modules (`typebox`,
`@earendil-works/pi-coding-agent`, `@earendil-works/pi-tui`), so the package
needs no npm dependency closure beyond the binary payload.

`sources.nix` carries the npm version, the extension `srcHash`, and a nested
`releases` record with the per-platform tarball package name and hash for
`x86_64-linux` and `aarch64-linux`. `update.sh` is npm-driven: it reads the
latest version from the registry, recomputes all three unpacked hashes with
`nix store prefetch-file --unpack`, and rewrites `sources.nix` atomically.
`--force` on the pinned version reproduces the file byte-for-byte.

## Pi wiring

`overlays/default.nix` exposes `pkgs.bladebro`; `users/pvl/pi/default.nix` uses
that attribute, adds the CLI to `home.packages`, and links
`.pi/agent/extensions/bladebro` to the package's `share/pi/packages/bladebro`
tree. Both are unconditional members of the shared Pvl Pi profile, so every host
that imports `users/pvl` (`core`, `dev`, and `lxc`) receives them; the headless
container profiles carry the package but have no Chrome to drive.

## Pi Web on pvl-a1

`hosts/pvl-a1/services/pi-web.nix` mirrors the pvl-l5 service and is imported
from `hosts/pvl-a1/services/default.nix`. It sets
`services.pi-web.tailnetAccess = true`, which binds `0.0.0.0:30141` and adds a
single nftables input rule for `iifname "tailscale0" tcp dport 30141`. The port
stays closed on every other interface; `allowedHosts` accepts the hostname and
its `tailcaaad.ts.net` MagicDNS name.

## Validation

- `nix build .#bladebro`; `bladebro --version` and `bladebro mcp --help` through
  the wrapped CLI.
- `patchelf --print-interpreter` on the payload shows the Nix glibc interpreter.
- `require.resolve("bladebro-linux-x64/package.json", {paths = [extensionDir]})`
  resolves to the packaged `node_modules` payload.
- `lib/ext/bladebro/update.sh --report` reports `4.5.0 [latest]`; `--force`
  leaves `sources.nix` unchanged.
- `nix eval .#nixosConfigurations.{pvl-a1,pvl-l5,pvl-x2,pvl-vk}.config.system.build.toplevel.drvPath`
  evaluates for the graphical and container hosts alike.
- `nix eval` confirms pvl-a1 `services.pi-web` is enabled with
  `tailnetAccess = true`, `ExecStart` binds `0.0.0.0:30141`, and the only added
  firewall rule is the `tailscale0` accept; the pvl-a1 home config links the
  bladebro extension and package.
- `scripts/update.sh --report --only-pkgs-ext` includes
  `bladebro: 4.5.0 [latest]`.
- `herdr integration status` with the built extension symlink reports
  `pi: current (v9)`; the pvl-a1 and pvl-l5 home activations contain the link,
  while container and non-Herdr hosts do not.
- `nix eval` of pvl-a1 and pvl-vk `system.build.toplevel.drvPath` still
  evaluates after the Pi wiring.
- `nix build` of `unstable.herdr-desktop` produces `herdr-app --version` 0.1.13
  and its `--help`/`--skill` entrypoints; `unstable.herdr-core` produces
  `hc --version` 0.1.18.

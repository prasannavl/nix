# dotlink MCP bridge on pvl-a1 and pvl-l5

On 2026-10-11 the Pvl hosts `pvl-a1` and `pvl-l5` gained a managed `dotlink`
service. dotlink is a permission-scoped local MCP bridge that opens an outbound
OpenAI Secure MCP Tunnel so ChatGPT (and other remote MCP clients) can work on
selected local projects without an inbound port or a third-party relay.

On 2026-10-13 the service was updated to `dotlink v0.8.0` and the NixOS module's
host-integration and developer-cache grants were enabled on both hosts (see
[Host access and developer caches](#host-access-and-developer-caches)). v0.8.1
followed the same day to fix a startup abort when a requested cache directory
was absent (see
[dotlink missing Go-module cache broke pvl-a1 activation](dotlink-missing-go-mod-cache-activation-failure-2026-10.md)).

## Flake input

`abird-ai/dotlink` is consumed as a root flake input because it ships both the
package and the `services.dotlink` NixOS module:

```nix
dotlink = {
  url = "github:abird-ai/dotlink";
  inputs = {
    nixpkgs.follows = "nixpkgs";
    crane.follows = "crane";
  };
};
```

dotlink's `nixpkgs` follows the repository's default `nixpkgs` (`nixos-26.05`);
its `crane` follows the root `crane` (`v0.24.0`). Its `rust-overlay` input
follows dotlink's `nixpkgs`, i.e. `26.05`. dotlink upstream targets
`nixos-unstable`, so this repository intentionally pins an older channel through
its own `nixpkgs`. Adding the input was purely additive — no existing input was
bumped.

The 2026-10-13 bump advanced only the `dotlink` node in `flake.lock` from
`3335af57` (2026-10-11) to `5e46cbf1` (2026-10-13); no other input moved. The
v0.8.1 fix advanced the same node to `5f46990` (2026-10-13); again no other
input moved.

## Host services

`hosts/pvl-a1/services/dotlink.nix` and `hosts/pvl-l5/services/dotlink.nix` are
identical and are imported from each host's `services/default.nix`:

```nix
imports = [inputs.dotlink.nixosModules.default];

services.dotlink = {
  enable = true;
  user = "pvl";
  workingDirectory = "/home/pvl/spaces/abird/";
  logging.verbosity = "tools";

  hostAccess = {
    nixDaemon = true;
    nixConfig = true;
    gitConfig = true;
    sshAgent = true;
  };
  cacheAccess = {
    "cargo-registry" = "rw";
    "cargo-git" = "rw";
    "npm" = "rw";
    "yarn" = "rw";
    "pip" = "rw";
    "go-mod" = "rw";
    "go-build" = "rw";
  };
};
```

The main `services.dotlink` instance becomes the `dotlink` systemd unit:

- `User = pvl`, `SetLoginEnvironment = true`, and
  `WorkingDirectory = /home/pvl/spaces/abird/` — the launch directory is the
  access root for relative grants and the default read permission.
- `ExecStart = <dotlink> --no-stdio --color=never --allow-shell
  --allow-nix-daemon --allow-nix-config --allow-ssh-agent --allow-git-config
  --allow-cache-<kind>=rw -v`.
  The `profile` option is left unset: the module maps both an unset selector and
  the literal `"default"` to the user's default dotlink profile, so the omitted
  value reuses that profile's runtime key and OAuth state.
  `logging.verbosity = "tools"` adds `-v` for tool activity (`"requests"` would
  add `-vv`). No secrets are placed in the Nix store.

`inputs` reaches host modules through `lib/flake/root.nix`'s `specialArgs`
(`selectedInputs = inputSet.inputs` already contains every top-level flake
input), so no `inputSetInputNames` entry is required.

The module only creates its `dotlink` system user when an instance uses
`user = "dotlink"`; the `pvl` instances do not, so no service user is added.

## Host access and developer caches

The 2026-10-13 change uses the module's own `hostAccess`/`cacheAccess` options
rather than declarative `settings`, so each host keeps reusing its saved profile
(including its per-host `tunnel_id` and OpenAI runtime key) while the repo stays
the source of truth for the host grants. The options map to `--allow-*` flags:

- `hostAccess.nixDaemon`/`nixConfig` →
  `--allow-nix-daemon`/`--allow-nix-config`, giving Bubblewrap shell tools the
  host Nix daemon and the user's XDG `nix.conf`, so `nix build`/`nix develop`
  work. No `~/.config/nix/nix.conf` exists on either host, so only the daemon
  socket is actually mounted today.
- `hostAccess.gitConfig` → `--allow-git-config`; mounts `~/.gitconfig` and
  `~/.config/git/config` read-only (`~/.gitconfig` exists on `pvl-l5` only).
- `hostAccess.sshAgent` → `--allow-ssh-agent`; the GCR socket at
  `/run/user/1000/gcr/ssh` is auto-discovered on both hosts (no `sshAgentSocket`
  override). The agent must already be running as `pvl` at service start.
- `cacheAccess` → `--allow-cache-<kind>=rw` for the seven caches present on both
  hosts (Cargo registry/git, npm, Yarn, pip, Go mod/build). Since v0.8.1 a cache
  whose directory is absent is skipped with a warning instead of aborting
  startup, so a configured-but-uncreated cache (for example `go-mod` on a host
  that never ran Go builds) no longer kills the unit. `pvl-a1` additionally has
  a `uv` cache that is only granted through its saved profile.

The module adds `--allow-shell` automatically whenever a host integration or
cache is requested. Shell **network** access is not a module option; it stays
enabled through each host's saved profile (`permissions.allow_network = true`,
along with `allow_shell = true` and the same seven caches).

## Build

The flake's default package compiles dotlink from source with `crane`. The
package is not exposed through `pkgs/manifest.nix`; it is referenced only by the
host service modules through the flake input, and the `dotlink` CLI is not added
to the hosts' `systemPackages`. A first run therefore requires one manual
`dotlink --setup` (and `--allow-*`) as user `pvl` on each host before the unit
can connect; the packaged binary is reachable at
`systemctl show -p ExecStart dotlink` if needed.

The v0.8.0 bump needed only seven derivations (Rust 1.98.1 toolchain plus
`dotlink-deps`/`dotlink`); the rest was substituted from the `pvl-x2` binary
cache. `dotlink v0.8.0` raises the profile schema to v10, which both hosts
already use or migrate to in memory. The v0.8.1 bump rebuilt `dotlink-0.8.1`
from source (about 1m25s) because the fixed binary was not yet in the cache.

## Validation

- `nix eval --raw .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath`
  and the same for `pvl-l5` evaluate.
- `nix eval` confirms `services.dotlink.user = "pvl"`,
  `workingDirectory = "/home/pvl/spaces/abird/"`, an unset `profile`, and the
  unit's `User`/`WorkingDirectory`/`SetLoginEnvironment`/`ExecStart`.
- `nix build .#nixosConfigurations.pvl-a1.config.services.dotlink.package`
  succeeds and `dotlink --version` reports `dotlink v0.8.1`.
- Both hosts evaluate to the same generated `ExecStart` with `--allow-shell`,
  `--allow-nix-daemon`, `--allow-nix-config`, `--allow-ssh-agent`,
  `--allow-git-config`, and the seven `--allow-cache-<kind>=rw` grants, and no
  `DOTLINK_CONFIG` (profile reuse).

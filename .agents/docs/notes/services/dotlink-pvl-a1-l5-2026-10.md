# dotlink MCP bridge on pvl-a1 and pvl-l5

On 2026-10-11 the Pvl hosts `pvl-a1` and `pvl-l5` gained a managed `dotlink`
service. dotlink is a permission-scoped local MCP bridge that opens an outbound
OpenAI Secure MCP Tunnel so ChatGPT (and other remote MCP clients) can work on
selected local projects without an inbound port or a third-party relay.

## Flake input

`abird-ai/dotlink` is consumed as a root flake input because it ships both the
package and the `services.dotlink` NixOS module:

```nix
dotlink = {
  url = "github:abird-ai/dotlink";
  inputs = {
    nixpkgs.follows = "unstable";
    crane.follows = "crane";
  };
};
```

dotlink targets `nixos-unstable`, so its `nixpkgs` follows the repository
`unstable`; its `crane` follows the root `crane` (both `v0.24.0`). Its
`rust-overlay` input follows dotlink's `nixpkgs`, i.e. `unstable`. The
`flake.lock` change is purely additive — no existing input was bumped.

## Host services

`hosts/pvl-a1/services/dotlink.nix` and `hosts/pvl-l5/services/dotlink.nix` are
identical and are imported from each host's `services/default.nix`:

```nix
imports = [inputs.dotlink.nixosModules.default];

services.dotlink = {
  enable = true;
  user = "pvl";
  workingDirectory = "/home/pvl/spaces/abird/";
};
```

The main `services.dotlink` instance becomes the `dotlink` systemd unit:

- `User = pvl`, `SetLoginEnvironment = true`, and
  `WorkingDirectory = /home/pvl/spaces/abird/` — the launch directory is the
  access root for relative grants and the default read permission.
- `ExecStart = <dotlink> --no-stdio --color=never`. The `profile` option is left
  unset: the module maps both an unset selector and the literal `"default"` to
  the user's default dotlink profile, so the omitted value reuses that profile's
  runtime key and OAuth state. No secrets are placed in the Nix store.

`inputs` reaches host modules through `lib/flake/root.nix`'s `specialArgs`
(`selectedInputs = inputSet.inputs` already contains every top-level flake
input), so no `inputSetInputNames` entry is required.

The module only creates its `dotlink` system user when an instance uses
`user = "dotlink"`; the `pvl` instances do not, so no service user is added.

## Build

The flake's default package compiles dotlink from source with `crane`: 104
derivations to build and ~948 MiB to unpack (mostly the Rust 1.98.1 toolchain
and the vendored crate registry). The package is not exposed through
`pkgs/manifest.nix`; it is referenced only by the host service modules through
the flake input, and the `dotlink` CLI is not added to the hosts'
`systemPackages`. A first run therefore requires one manual `dotlink --setup`
(and `--allow-*`) as user `pvl` on each host before the unit can connect; the
packaged binary is reachable at `systemctl show -p ExecStart dotlink` if needed.

## Validation

- `nix eval --raw .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath`
  and the same for `pvl-l5` evaluate.
- `nix eval` confirms `services.dotlink.user = "pvl"`,
  `workingDirectory = "/home/pvl/spaces/abird/"`, an unset `profile`, and the
  unit's `User`/`WorkingDirectory`/`SetLoginEnvironment`/`ExecStart`.
- `nix build .#nixosConfigurations.pvl-a1.config.services.dotlink.package`
  succeeds and `dotlink --version` reports `dotlink v0.7.0`.

# Native Services

This document describes the repo pattern for turning local packages into
services and timers.

The rule is simple: stick to the simplest native Linux patterns. We do not add
an extra service framework on top. If something is a long-running process, use
`systemd.services`. If something is scheduled, use `systemd.timers`.

## Current Model

- Packages live under `pkgs/<name>/`.
- The canonical package definition lives in `pkgs/<name>/default.nix`.
- The package-local `flake.nix` can export a `nixosModules` entry alongside the
  package.
- Hosts enable the service with `services.<name>.enable = true`.
- The module then writes normal `systemd.services.<name>` and, when needed,
  normal `systemd.timers.<name>`.

## Guiding Principle

Prefer the most native NixOS shape:

- package definition in `default.nix`
- optional wrapper flake for local UX
- NixOS module under `nixosModules`
- host-side enablement through `services.<name>.enable`
- plain systemd service and timer definitions in the module

The repo goal is not to invent its own service model. The repo only establishes
patterns and naming conventions on top of the standard Linux model so services
are defined consistently.

That means:

- prefer standard module options over custom wrappers
- prefer plain `systemd.services` and `systemd.timers` over helper DSLs
- prefer the native operating model of each tool, for example systemd for
  services, Incus for containers, and Podman for container workloads
- prefer small, obvious conventions over new abstractions

No repo-specific service abstraction is needed for ordinary system services.

## Package To Service Pattern

The reference example is `pkgs/hello-rust/flake.nix`.

It does three things:

1. builds the package
2. exports the package and app from the flake
3. exports a NixOS module that adds `services.hello-rust.enable`

The service module shape is:

```nix
nixosModules = let
  helloRustModule = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.hello-rust;
  in {
    options.services.hello-rust = {
      enable = lib.mkEnableOption "hello-rust service";

      package = lib.mkOption {
        type = lib.types.package;
        inherit (self.packages.${pkgs.system}) default;
        defaultText = lib.literalExpression
          "self.packages.${pkgs.system}.default";
      };
    };

    config = lib.mkIf cfg.enable {
      systemd.services.hello-rust = {
        description = "hello-rust";
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig = {
          ExecStart = "${cfg.package}/bin/hello-rust";
          Restart = "on-failure";
        };
      };
    };
  };
in {
  default = helloRustModule;
  hello-rust = helloRustModule;
};
```

This is the canonical package-to-service pattern in this repo.

## Host Enablement Pattern

Once a package flake exports a NixOS module, a host can import or consume that
module and then enable the service normally:

```nix
{
  imports = [
    inputs.hello-rust.nixosModules.default
  ];

  services.hello-rust.enable = true;
}
```

If the module exposes a `package` option, the host can also override which build
is run:

```nix
{
  services.hello-rust = {
    enable = true;
    package = inputs.hello-rust.packages.${pkgs.system}.default;
  };
}
```

## Timers

Timers should also stay native.

If a package needs scheduled execution, define:

- `systemd.services.<name>`
- `systemd.timers.<name>`

Example pattern:

```nix
config = lib.mkIf cfg.enable {
  systemd.services.my-job = {
    description = "my-job";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${cfg.package}/bin/my-job";
    };
  };

  systemd.timers.my-job = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };
};
```

That is the preferred shape instead of inventing a repo-specific scheduling
layer.

## What To Put Where

- `pkgs/<name>/default.nix`:
  - canonical package build
- `pkgs/<name>/flake.nix`:
  - package-local wrapper flake
  - optional `apps`
  - optional `checks`
  - optional `nixosModules`
- host module:
  - imports the exported module
  - sets `services.<name>.enable = true`
  - applies host-local configuration overrides

## How To Add A New Service

1. Create `pkgs/<name>/default.nix`.
2. Add the package to `lib/flake/packages.nix` if it should be exported from the
   root flake package set.
3. Add or update `pkgs/<name>/flake.nix`.
4. Export a `nixosModules.default` module.
5. Add `options.services.<name>.enable = lib.mkEnableOption ...`.
6. Under `config = lib.mkIf cfg.enable`, define native
   `systemd.services.<name>`.
7. If the job is scheduled, also define native `systemd.timers.<name>`.
8. Import the module on the target host and set `services.<name>.enable = true`.

## FAQ

### Why not add a shared repo abstraction for ordinary services?

Because NixOS already has a very good one: native modules plus native systemd
units. Extra abstraction only hides the real behavior. More broadly, the repo
should define consistent patterns, not replace the native Linux standard of the
tool we are using.

### Where should the package live?

In `pkgs/<name>/default.nix`. That remains the canonical package definition.

### Where should the service module live?

For package-owned services, the preferred place is the package-local
`pkgs/<name>/flake.nix`, exported through `nixosModules`.

### Should timers use a custom helper?

No. Use normal `systemd.timers` unless there is a very strong reason not to.

### How should hosts enable the service?

With the native NixOS option exposed by the module:
`services.<name>.enable = true`.

## Related Docs

- `docs/podman-compose.md`: Podman compose container workloads.
- `docs/incus-vms.md`: Incus guest lifecycle.
- `docs/systemd-user-manager.md`: Deploy-time user-service bridge module.
- `docs/deployment.md`: Deploy architecture and secret model.

## Source Of Truth Files

- `pkgs/hello-rust/default.nix`
- `pkgs/hello-rust/flake.nix`
- `lib/flake/packages.nix`

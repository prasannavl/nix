# Native Services

Use native NixOS modules and native systemd units for ordinary services.

## Rules

- Keep the canonical package build in `pkgs/<name>/default.nix`.
- Use a package-local `flake.nix` for local UX and optional `nixosModules`.
- Expose a NixOS module under `nixosModules`.
- Enable the service from the host with `services.<name>.enable = true`.
- Define plain `systemd.services` and `systemd.timers`.

Do not add a repo-specific service abstraction on top of NixOS modules and
systemd.

## Standard Pattern

The reference example is `pkgs/examples/hello-rust/flake.nix`.

Typical service module shape:

```nix
nixosModules = let
  myModule = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.my-service;
  in {
    options.services.my-service = {
      enable = lib.mkEnableOption "my service";

      package = lib.mkOption {
        type = lib.types.package;
        inherit (self.packages.${pkgs.system}) default;
        defaultText = lib.literalExpression
          "self.packages.${pkgs.system}.default";
      };
    };

    config = lib.mkIf cfg.enable {
      systemd.services.my-service = {
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig.ExecStart = "${cfg.package}/bin/my-service";
      };
    };
  };
in {
  default = myModule;
};
```

## Host Usage

```nix
{
  imports = [
    inputs.my-service.nixosModules.default
  ];

  services.my-service.enable = true;
}
```

If the module exposes a `package` option, the host can override the package.

## Timers

If the service is scheduled, define native timer units:

```nix
config = lib.mkIf cfg.enable {
  systemd.services.my-job = {
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

## Add A Service

1. Create `pkgs/<name>/default.nix`.
2. Add the package to the root export set if needed.
3. Add or update `pkgs/<name>/flake.nix`.
4. Export `nixosModules.default`.
5. Add `services.<name>.enable`.
6. Define native `systemd.services.<name>`.
7. Add `systemd.timers.<name>` if scheduled.
8. Import and enable the module from the target host.

## Related Docs

- [`docs/podman-compose.md`](./podman-compose.md)
- [`docs/incus-vms.md`](./incus-vms.md)
- [`docs/systemd-user-manager.md`](./systemd-user-manager.md)

## Detailed Reference

The sections below cover philosophy, placement rules, and FAQs.

## Guiding Principle

Use the native NixOS model: package in `default.nix`, optional package-local
`flake.nix`, NixOS module under `nixosModules`, and plain
`systemd.services`/`systemd.timers`. This repo standardizes naming and layout.
It does not add a separate service framework for ordinary system services.

## What To Put Where

- package-local `default.nix`:
  - canonical package build
- package-local `flake.nix`:
  - package-local wrapper flake
  - optional `apps`
  - optional `checks`
  - optional `nixosModules`
- host module:
  - imports the exported module
  - sets `services.<name>.enable = true`
  - applies host-local configuration overrides

## How To Add A New Service

1. Create the package-local `default.nix` under `pkgs/`.
2. Add the package to `lib/flake/packages.nix` if it should be exported from the
   root flake package set.
3. Add or update the package-local `flake.nix`.
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

In the package-local `default.nix`. That remains the canonical package
definition.

### Where should the service module live?

For package-owned services, the preferred place is the package-local the
package-local `flake.nix`, exported through `nixosModules`.

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

- `pkgs/examples/hello-rust/default.nix`
- `pkgs/examples/hello-rust/flake.nix`
- `lib/flake/packages.nix`

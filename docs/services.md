# Native Services

Use native NixOS modules and native systemd units for ordinary services.

## Rules

- Keep the canonical package build in `pkgs/<name>/default.nix`.
- Keep package-owned NixOS modules on the canonical derivation as
  `passthru.nixosModule`.
- Use a package-local `flake.nix` for local commands and module exports. The
  shared child-flake builder exports `nixosModules.default` from
  `passthru.nixosModule`.
- Enable the service from the host with `services.<name>.enable = true`.
- Define plain `systemd.services` and `systemd.timers`.

Do not add a repo-specific service abstraction on top of NixOS modules and
systemd.

## Standard Pattern

The reference example is `pkgs/examples/hello-rust/default.nix` plus its thin
`flake.nix` wrapper.

Typical service module shape:

```nix
{pkgs, ab}:
ab.build.rust {
  inherit pkgs;
  pname = "my-service";
  version = "0.1.0";
  projectDir = "pkgs/my-service";
  extraPassthru.nixosModule = ab.nixos.service {};
}
```

As in the `hello-rust` example, the child `flake.nix` uses
`(import ../../../lib/project.nix).mkFlakeOutputs ./. inputs`. This builds the
same constructor as the root package set and exports `nixosModules.default` from
`passthru.nixosModule`.

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
4. Attach `passthru.nixosModule` on the derivation and re-export it from the
   child flake.
5. Add `services.<name>.enable`.
6. Define native `systemd.services.<name>`.
7. Add `systemd.timers.<name>` if scheduled.
8. Import and enable the module from the target host.

## Further Reading

- [`docs/podman-compose.md`](./podman-compose.md)
- [`docs/incus-vms.md`](./incus-vms.md)

## Detailed Reference

The sections below cover philosophy, placement rules, and FAQs.

## Guiding Principle

Use the native NixOS model: package in `default.nix`, optional package-local
`flake.nix`, package-owned module on `passthru.nixosModule`, and plain
`systemd.services`/`systemd.timers`. This repo standardizes naming and layout
and may use shared helper builders, but it does not replace the native NixOS
service model for ordinary system services.

## What To Put Where

- package-local `default.nix`:
  - canonical package build
  - package-owned `passthru.nixosModule` when the package exports a service
- package-local `flake.nix`:
  - package-local wrapper flake
  - optional `apps`
  - optional `checks`
  - re-exported `nixosModules`
- host module:
  - imports the exported module
  - sets `services.<name>.enable = true`
  - applies host-local configuration overrides

## How To Add A New Service

1. Create the package-local `default.nix` under `pkgs/`.
2. Add the package to `pkgs/manifest.nix` if it should be exported from the root
   flake package set. Repository package composition is exposed through
   `ab.repo.packages`.
3. Add or update the package-local `flake.nix`.
4. Attach `passthru.nixosModule` to the derivation for the child flake to
   re-export.
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

For package-owned services, the preferred place is the package derivation's
`passthru.nixosModule`, with the child flake re-exporting it through
`nixosModules`.

### Should timers use a custom helper?

No. Use normal `systemd.timers` unless there is a very strong reason not to.

### How should hosts enable the service?

With the native NixOS option exposed by the module:
`services.<name>.enable = true`.

## Related Docs

- `docs/podman-compose.md`: Podman compose container workloads.
- `docs/incus-vms.md`: Incus guest lifecycle.
- `docs/deployment.md`: Deploy architecture and secret model.

## Source Of Truth Files

- `pkgs/examples/hello-rust/default.nix`
- `pkgs/examples/hello-rust/flake.nix`
- `lib/project.nix`
- `pkgs/manifest.nix`
- `ab/repo/packages.nix`

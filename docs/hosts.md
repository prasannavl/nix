# Hosts

This document describes the host model, directory conventions, and the
step-by-step process for adding a new host.

## Philosophy

This repo manages NixOS hosts **agnostic of where they run**. A host can be a
physical machine, a VM on any hosted provider (GCP, AWS, Hetzner, etc), an Incus
container on a local server, laptop, edge device or anything that boots NixOS.
The repo does not encode provider-specific logic at the host level — all hosts
are first-class citizens regardless of their backing infrastructure.

The same `nixbot` deploy flow, the same secret model, and the same module
composition apply whether the target is a laptop on the desk or a VM on the
other side of the world.

## Current Model

- Each host is a directory under `hosts/<host-name>/`.
- `hosts/default.nix` is the registry that wires every host into
  `nixosConfigurations`.
- `hosts/nixbot.nix` is the deploy target mapping consumed by `nixbot`.
- Shared NixOS modules live in `lib/`.
- Profiles under `lib/profiles/` provide layered baseline configuration.
- Device modules under `lib/devices/` encode hardware-specific quirks.
- `commonModules` is assembled in `flake.nix` and includes `home-manager`,
  `agenix`, overlays, and shared `home-manager` args.

## Directory Layout

```
hosts/
  default.nix                # registry — all nixosConfigurations
  nixbot.nix                 # deploy target mapping
  <host-name>/
    default.nix              # entry point — imports and profile selection
    sys.nix                  # hardware config (physical machines only)
    packages.nix             # host-specific packages
    firewall.nix             # host-specific firewall rules
    users.nix                # host-specific user declarations
    services.nix             # host-specific service configuration
    podman.nix               # podman compose stacks
    cloudflare.nix           # Cloudflare tunnel config
    incus.nix                # Incus guest declarations (parent hosts)
    compose/<stack>/...      # compose files for podman stacks
```

Not every host has every file. The split is by concern — only create a file when
the host needs host-specific configuration for that concern.

## Profiles

Profiles under `lib/profiles/` provide layered baseline configuration. A host's
`default.nix` imports the appropriate profile as its foundation.

- `core.nix` — foundational system config: boot, networking, security, locale,
  users, nix settings, neovim, hardware, systemd, sysctl, and essential CLI
  tools.
- `systemd-container.nix` — minimal profile for Incus/container guests with no
  physical hardware assumptions.
- `desktop-core.nix` — desktop foundations (imports `core.nix`).
- `desktop-gnome.nix` / `desktop-gnome-minimal.nix` — GNOME desktop variants.
- `all.nix` — full desktop profile (imports `desktop-gnome.nix`).

Physical machines typically use `all.nix`. Incus VM guests use
`systemd-container.nix` plus `lib/incus-vm.nix`.

## How To Add A New Host

### 1. Choose a hostname

No strict naming scheme is enforced, but existing hosts use lowercase with
hyphens. Nested guests typically include the parent host's prefix.

### 2. Create the host directory

Create `hosts/<host-name>/default.nix` as the entry point. This file imports the
appropriate profile and any host-specific modules.

For a physical machine:

```nix
{...}: {
  imports = [
    ../../lib/devices/<device>.nix
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./users.nix
  ];
}
```

For an Incus VM guest:

```nix
{hostName, ...}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ../../lib/podman.nix
    ../../lib/podman-compose.nix
    ./packages.nix
    ./services.nix
    ./users.nix
  ];
}
```

### 3. Add hardware config (physical machines only)

Generate with `nixos-generate-config` and move the hardware configuration into
`sys.nix`. This contains boot configuration, filesystem declarations, kernel
modules, and platform detection.

Incus VM guests do not need `sys.nix` — `lib/incus-vm.nix` handles the virtual
hardware.

### 4. Register the host

Add the host to `hosts/default.nix`:

```nix
<host-name> = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = {
    inputs = inputs;
    hostName = "<host-name>";
  };
  modules = commonModules ++ [./<host-name>];
};
```

### 5. Add deploy configuration

Add an entry in `hosts/nixbot.nix`:

```nix
<host-name> = {
  target = "<host-name-or-ip>";
  ageIdentityKey = "data/secrets/machine/<host-name>.key.age";
};
```

Common optional fields:

- `proxyJump = "<bastion-host>";` — when the host is not directly reachable.
- `after = ["<dependency-host>"];` — deploy ordering.
- `deploy = "optional";` — when deploy failures are non-blocking.

### 6. Provision secrets

Each deployed host needs a machine age key pair:

- `data/secrets/machine/<host-name>.key`
- `data/secrets/machine/<host-name>.key.pub`
- `data/secrets/machine/<host-name>.key.age`

See `docs/deployment.md` for the full bootstrap and re-encryption procedure.

### 7. Add host-specific modules

Split configuration into concern-specific files as needed. Only create files for
concerns the host actually has.

### 8. Deploy

Deploy the host through `nixbot`. For Incus guests, deploy the parent host first
so the guest is created, then deploy the guest itself.

## Shared Modules

Host-specific modules import shared functionality from `lib/`:

| Module                     | Purpose                                     |
| -------------------------- | ------------------------------------------- |
| `lib/podman.nix`           | Shared Podman enablement and config         |
| `lib/podman-compose.nix`   | Podman compose platform                     |
| `lib/incus.nix`            | Declarative Incus guest lifecycle           |
| `lib/incus-vm.nix`         | Incus VM guest hardware config              |
| `lib/swap-auto.nix`        | Automatic swap configuration                |
| `lib/nixbot/`              | Deploy agent integration                    |
| `lib/nixbot/bastion.nix`   | Bastion host role for deploy relay          |
| `lib/devices/<device>.nix` | Hardware-specific kernel modules and quirks |

## Host Types

### Physical machines

Physical machines import a device module for hardware-specific configuration, a
full profile like `all.nix`, and `sys.nix` generated by `nixos-generate-config`.

### Incus VM guests

Incus guests use `systemd-container.nix` as their profile, import
`lib/incus-vm.nix` for virtual hardware, and are declared on their parent host
via `lib/incus.nix`. They are full NixOS hosts in `hosts/` with their own
directory, registered in `hosts/default.nix` and `hosts/nixbot.nix` like any
other host. See `docs/incus-vms.md` for the full lifecycle model.

### Cloud VMs

Cloud VMs (any provider) follow the physical machine pattern: generate hardware
config into `sys.nix`, pick an appropriate profile, and register normally. The
repo does not special-case any cloud provider.

## Tailscale

All physical hosts join the same Tailscale network automatically.
`lib/network.nix` enables `services.tailscale` as part of the base networking
profile imported by `lib/profiles/core.nix`, so every host that uses any profile
built on `core.nix` is a Tailscale member with zero per-host configuration.

Incus VM guests join automatically too, but through a different mechanism.
`lib/incus-vm.nix` checks for a Tailscale auth key at
`data/secrets/tailscale/<host-name>.key.age`. When that file exists, the module:

- Decrypts it via `agenix`.
- Enables `services.tailscale`.
- Passes the auth key with `preauthorized = true` and `ephemeral = false`.
- Advertises `--advertise-tags=tag:vm`.

To add a new Incus guest to the Tailscale network:

1. Generate or obtain a Tailscale auth key for the guest.
2. Store it at `data/secrets/tailscale/<host-name>.key`.
3. Encrypt it: `data/secrets/tailscale/<host-name>.key.age`.
4. Re-encrypt secrets and deploy.

If the auth key file does not exist, Tailscale is simply not enabled on that
guest — no error, no config.

The `tailscaleKey` parameter on `lib/incus-vm.nix` defaults to the hostname but
can be overridden if the secret file uses a different name.

## Cloudflare Tunnels

Hosts that need to expose services to the internet use Cloudflare Tunnels. This
uses the stock NixOS `services.cloudflared` module directly — there is no
repo-specific wrapper.

Each tunneled host has a `cloudflare.nix` file that:

1. Decrypts the tunnel credentials JSON from
   `data/secrets/cloudflare/tunnels/<host>-main.credentials.json.age` via
   `agenix`.
2. Configures `services.cloudflared.tunnels."<tunnel-uuid>"` with the
   credentials file and ingress rules.

Example shape:

```nix
{config, lib, ...}: let
  s = ../../data/secrets
    + "/cloudflare/tunnels/<host>-main.credentials.json.age";
  c =
    if builtins.pathExists s
    then builtins.path {path = s; name = "<host>-main.credentials.json.age";}
    else null;
in {
  age.secrets = lib.optionalAttrs (c != null) {
    cloudflare-tunnel-main-credentials = {
      file = c;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.cloudflared = lib.mkIf (c != null) {
    enable = true;
    tunnels."<tunnel-uuid>" = {
      credentialsFile =
        config.age.secrets.cloudflare-tunnel-main-credentials.path;
      default = "http_status:404";
      ingress = {
        "app.example.com" = "http://127.0.0.1:3000";
      };
    };
  };
}
```

For hosts running Podman compose stacks with `exposedPorts` metadata, the
ingress map can be derived automatically from the stack configuration via
`config.services.podmanCompose.<stack>.cloudflareTunnelIngress` instead of being
written by hand.

To add Cloudflare Tunnel support to a new host:

1. Create the tunnel in Cloudflare (via Terraform in `tf/cloudflare-platform/`
   or manually).
2. Store the credentials JSON at
   `data/secrets/cloudflare/tunnels/<host>-main.credentials.json`.
3. Encrypt it as `.age` and re-encrypt secrets.
4. Create `hosts/<host-name>/cloudflare.nix` following the pattern above.
5. Import `./cloudflare.nix` from the host's `default.nix`.
6. Deploy.

## NixOS Images

Reusable base images (e.g. for Incus templates) live in `lib/images/` and use
the same `commonModules` mechanism. They are not registered in
`hosts/default.nix` because they are not deploy targets.

## FAQ

### Does a host need to be a physical machine?

No. A host can be anything that boots NixOS: a physical machine, a cloud VM on
any provider, an Incus container, or a nested VM inside another host. The repo
treats them all the same.

### Do I need a device module for a cloud VM?

No. Device modules are for physical hardware quirks. Cloud VMs typically only
need `sys.nix` from `nixos-generate-config`.

### What profile should I use?

- Physical machines with a desktop: `all.nix`
- Headless physical machines or cloud VMs: `core.nix`
- Incus/container guests: `systemd-container.nix`

### How does deploy reach hosts behind NAT or firewalls?

Use `proxyJump` in `hosts/nixbot.nix` to route deploy SSH through a bastion
host. Chain multiple hops with `after` for ordering.

### Can I deploy a single host?

Yes. `nixbot deploy --hosts <host-name>` targets a single host.

## Related Docs

- `docs/incus-vms.md`: Incus guest lifecycle, tags, and device model.
- `docs/services.md`: Native service pattern.
- `docs/podman-compose.md`: Podman compose container workloads.
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.

## Source Of Truth Files

- `hosts/default.nix`
- `hosts/nixbot.nix`
- `hosts/<host-name>/default.nix`
- `lib/profiles/`
- `lib/devices/`
- `lib/network.nix` (Tailscale enablement for physical hosts)
- `lib/incus-vm.nix` (Tailscale auto-wiring for Incus guests)
- `hosts/<host-name>/cloudflare.nix` (per-host tunnel config)
- `flake.nix` (`commonModules`)

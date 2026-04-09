# Hosts

This repo manages NixOS hosts under `hosts/` and deploys them through `nixbot`.

## What Matters

- Each host lives in `hosts/<host-name>/`.
- `hosts/default.nix` registers hosts into `nixosConfigurations`.
- `hosts/nixbot.nix` defines deploy targets and ordering.
- Shared modules live in `lib/`.
- Profiles live in `lib/profiles/`.
- Device-specific hardware modules live in `lib/devices/`.

The repo does not encode provider-specific host models. Physical machines, cloud
VMs, and Incus guests use the same host layout and deploy flow.

## Common Host Layout

```text
hosts/
  default.nix
  nixbot.nix
  <host-name>/
    default.nix
    sys.nix
    packages.nix
    firewall.nix
    users.nix
    services.nix
    podman.nix
    cloudflare.nix
    incus.nix
    compose/<stack>/...
```

Only keep files that the host actually uses.

## Profiles

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

## Add A Host

1. Create `hosts/<host-name>/default.nix`.
2. Import the right profile and only the host-local modules you need.
3. Add `sys.nix` only for physical machines or other hosts with local hardware
   config.
4. Register the host in `hosts/default.nix`.
5. Add deploy metadata to `hosts/nixbot.nix`.
6. If the host is an Incus guest, also declare it on the parent host in
   `hosts/<parent>/incus.nix`.

## Minimal Host Shapes

Physical machine or VM:

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

Incus guest:

```nix
{hostName, ...}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ./packages.nix
    ./users.nix
  ];
}
```

## Register A Host

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

## Deploy Metadata

Add an entry to `hosts/nixbot.nix`:

```nix
<host-name> = {
  target = "<host-or-ip>";
  ageIdentityKey = "data/secrets/machine/<host-name>.key.age";
};
```

Common optional fields:

- `proxyJump = "<bastion-host>";`
- `parent = "<parent-host>";`
- `after = [ ... ];`
- bootstrap fields for first-time access when needed

Use `parent` for nested guest relationships. Do not add redundant `after` edges
just to get the parent deployed first.

## Physical Hosts

- Generate hardware config with `nixos-generate-config`.
- Move the hardware-specific output into `hosts/<host>/sys.nix`.
- Keep `sys.nix` limited to hardware, filesystems, boot, and platform-specific
  kernel settings.

## Incus Guests

- Declare the guest in the parent host's `incus.nix`.
- Give it a stable `ipv4Address`.
- Add a persistent `/var/lib` disk unless the guest is intentionally stateless.
- Use extra devices only when required.

See [`docs/incus-vms.md`](./incus-vms.md) for the guest lifecycle and
[`docs/incus-readiness.md`](./incus-readiness.md) for deploy-time readiness.

## Quick Links

- [`docs/deployment.md`](./deployment.md)
- [`docs/ssh-access.md`](./ssh-access.md)
- [`docs/incus-vms.md`](./incus-vms.md)
- [`docs/services.md`](./services.md)
- [`docs/podman-compose.md`](./podman-compose.md)

## Detailed Reference

The sections below cover provisioning details, shared modules, and host-type
notes.

### 7. Provision secrets

Each deployed host needs a machine age key pair:

- `data/secrets/machine/<host-name>.key`
- `data/secrets/machine/<host-name>.key.pub`
- `data/secrets/machine/<host-name>.key.age`

Current repo workflow:

1. Generate the machine identity:

   ```bash
   age-keygen -o data/secrets/machine/<host-name>.key
   ```

2. Save the printed `Public key: ...` value to
   `data/secrets/machine/<host-name>.key.pub`.
3. Add the new public key file to `machineKeyFiles` in
   `data/secrets/default.nix`.
4. Add the managed `data/secrets/machine/<host-name>.key.age` recipient entry to
   `data/secrets/default.nix`.
5. Encrypt the managed secret:

   ```bash
   ./scripts/age-secrets.sh encrypt data/secrets/machine/<host-name>.key
   ```

6. Remove the plaintext private key after encryption succeeds:

   ```bash
   ./scripts/age-secrets.sh clean data/secrets/machine/<host-name>.key
   ```

Optional guest-local Tailscale auth uses the same pattern at
`data/secrets/tailscale/<host-name>.key.age`.

See `docs/deployment.md` for the full bootstrap and re-encryption procedure.

### 8. Add host-specific modules

Split configuration into concern-specific files as needed. Only create files for
concerns the host actually has.

### 9. Deploy

Deploy the host through `nixbot`. For Incus guests, deploy the parent host first
so the guest is created, then deploy the guest itself.

## Shared Modules

Host-specific modules import shared functionality from `lib/`:

| Module                     | Purpose                                     |
| -------------------------- | ------------------------------------------- |
| `lib/podman.nix`           | Shared Podman enablement and config         |
| `lib/podman-compose/`      | Podman compose platform module and helper   |
| `lib/incus/default.nix`    | Declarative Incus guest lifecycle           |
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
via `lib/incus/default.nix`. They are full NixOS hosts in `hosts/` with their
own directory, registered in `hosts/default.nix` and `hosts/nixbot.nix` like any
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
uses the stock NixOS `services.cloudflared` module directly; there is no
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

1. Create the tunnel in Cloudflare via the normal platform workflow.
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

### Can I deploy a single host?

Yes. `nixbot deploy --hosts <host-name>` targets a single host.

## Further Reading

- `docs/incus-vms.md`: Incus guest lifecycle, tags, and device model.
- `docs/services.md`: Native service pattern.
- `docs/podman-compose.md`: Podman compose container workloads.
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.
- `docs/ssh-access.md`: Operator SSH access and deploy SSH routing.

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

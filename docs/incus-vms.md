# Incus VMs

This document describes the current Incus guest model, using a representative
guest as the template for future guests.

## Current Model

- Parent host: the bastion/virtualization host
- Parent-host Incus orchestration: `hosts/<parent-host>/incus.nix`
- Reusable bootstrap image: `lib/images/incus-bootstrap.nix`
- Shared guest bootstrap module: `lib/incus-machine.nix`
- Guest host definition example: `hosts/<guest>/default.nix`
- Deploy mapping: `hosts/nixbot.nix`

## What Is Reusable

- The bootstrap image is generic. It is not specific to any one guest.
- `lib/incus-machine.nix` handles the shared guest mechanics:
  - persistent SSH host keys under `/var/lib/machine`
  - optional Tailscale auth wiring from `data/secrets/tailscale/<host>.key.age`
- The guest's real config still lives under `hosts/<name>/`.
- `nixbot` still treats the guest as a normal host after bootstrap.

## Secret Model For Incus Guests

- Required, same as any other host:
  - `data/secrets/machine/<host>.key.age`
- Optional:
  - `data/secrets/tailscale/<host>.key.age`
- Not repo-managed secrets:
  - `/var/lib/machine/ssh_host_ed25519_key`
  - `/var/lib/machine/ssh_host_rsa_key`

Incus itself is not carrying a separate secret exchange here. The guest enters
the same `nixbot` + machine-age-identity model used by other nodes.

## How A Guest Works Today

A representative guest is defined across four layers:

1. Flake host entry
   - `hosts/default.nix` defines the guest as a normal `nixosConfiguration`
2. Guest OS composition
   - `hosts/<guest>/default.nix` imports:
     - `lib/profiles/systemd-container.nix`
     - `lib/incus-machine.nix`
     - host-local modules for packages, firewall, podman, services, users
3. Parent-host creation/start
   - `hosts/<parent-host>/incus.nix` creates and starts the Incus guest from the
     reusable bootstrap image
4. Deploy targeting
   - `hosts/nixbot.nix` points deploys at the guest's stable Incus address,
     recorded in config rather than docs

## How To Create A New Guest

Use an existing guest as the template.

1. Add the new host configuration.
   - Create `hosts/<name>/default.nix`
   - Import `../../lib/profiles/systemd-container.nix`
   - Import `(import ../../lib/incus-machine.nix { inherit hostName; })`
   - Add host-local modules as needed
2. Register the host in `hosts/default.nix`.
   - Add a new `nixosSystem` entry for `<name>`
3. Add the guest to the parent host's Incus map in
   `hosts/<parent-host>/incus.nix`.
   - pick a stable IPv4 address on `incusbr0`
   - create a persistent state dir under `/var/lib/machines/<name>`
   - add any extra Incus device commands needed for that guest
4. Add deploy metadata in `hosts/nixbot.nix`.
   - set `target` to the guest's stable Incus IP
   - set `ageIdentityKey = "data/secrets/machine/<name>.key.age"`
   - set `deps = [ "<parent-host>" ]` if the guest depends on the parent host
     being present
5. Add machine identity secrets.
   - commit `data/secrets/machine/<name>.key.pub`
   - encrypt `data/secrets/machine/<name>.key.age`
   - add the recipient mapping in `data/secrets/default.nix`
6. Optionally add Tailscale auth.
   - create `data/secrets/tailscale/<name>.key.age`
   - add its recipient mapping in `data/secrets/default.nix`
7. Re-encrypt managed secrets.
   - `scripts/age-secrets.sh encrypt data/secrets`
   - `scripts/age-secrets.sh clean data/secrets`
8. Deploy the parent host.
   - this imports/refreshes the generic bootstrap image
   - creates the guest if missing
   - attaches persistent storage and any extra devices
   - starts the guest
9. Deploy the guest through `nixbot`.
   - first deploy injects `/var/lib/nixbot/.age/identity`
   - later deploys use the normal steady-state `nixbot` path

## What `hosts/<parent-host>/incus.nix` Must Provide

For each guest entry:

- `ipv4Address`
- `stateDir`
- `stateDirMode`
- `extraCreateCommands`

The parent-host service then:

- ensures the generic bootstrap image exists
- `incus create`s the guest if it does not exist
- configures:
  - `security.privileged=false`
  - `security.nesting=true`
  - persistent `/var/lib` disk from the host state dir
  - stable `eth0` IPv4 address
- runs any per-guest device additions
- starts the guest

## Bootstrap And First Deploy Flow

There are two phases.

Phase 1: Incus bootstrap on the parent host

- the parent host imports the reusable image into Incus
- the parent host creates the guest from that image
- the guest boots a minimal reusable NixOS/container base

Phase 2: Guest switch to real host config

- `nixbot` deploy targets the guest's stable Incus IP from `hosts/nixbot.nix`
- deploy injects `data/secrets/machine/<host>.key.age` to
  `/var/lib/nixbot/.age/identity`
- activation switches the guest to its real `hosts/<name>/` configuration

After phase 2, the guest behaves like any other managed node.

## Template Checklist

For a new guest, make sure all of these exist:

- `hosts/<name>/default.nix`
- `hosts/default.nix` entry
- `hosts/<parent-host>/incus.nix` entry
- `hosts/nixbot.nix` entry
- `data/secrets/machine/<name>.key.pub`
- `data/secrets/machine/<name>.key.age`
- optional `data/secrets/tailscale/<name>.key.age`
- matching `data/secrets/default.nix` recipient entries

## Notes

- Keep live guest names and addresses in config, not in documentation.
- Older notes with concrete guest addresses should be treated as stale.

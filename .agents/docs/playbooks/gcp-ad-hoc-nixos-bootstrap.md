# GCP Ad Hoc NixOS Bootstrap

## Goal

Create an ad hoc GCP VM with `gcloud`, install a repo-defined NixOS host onto
it, and land in the repo's normal `nixbot` / agenix steady state instead of
keeping a snowflake bootstrap box.

## Preconditions

1. Prepare the repo host before touching GCP.
   - Add the host to `hosts/default.nix` so `.#nixosConfigurations.<host>`
     evaluates.
   - Add the host to `hosts/nixbot.nix` with a real `ageIdentityKey`.
   - Ensure the host config is installable on the intended GCP disk / boot
     layout. These scripts do not synthesize a GCE-specific host module for you.
2. Ensure the repo secrets already exist.
   - The host machine identity secret referenced by `hosts/nixbot.nix` must be
     present.
   - The shared deploy key from `hosts/nixbot.nix` must be decryptable locally.
3. Ensure the operator machine has:
   - `nix`
   - a bootstrap SSH keypair, defaulting to `~/.ssh/id_ed25519`
   - an age decrypt identity, defaulting to `$AGE_KEY_FILE` or
     `~/.ssh/id_ed25519`
   - working `gcloud` auth for the chosen project
   - note: the scripts self-enter one shared standalone `nix shell` runtime for
     `gcloud`, `jq`, `age`, `nixos-anywhere`, and OpenSSH; they do not depend on
     the repo flake for these tool dependencies
4. If the host will act as a Tailscale subnet router:
   - enable the cloud-side GCP `canIpForward` flag when creating the VM
   - also enable guest-side IP forwarding and `tailscale up --advertise-routes`
     in the host's NixOS config; the GCP script only handles the cloud-side
     instance setting and fw rules

## Why Nixify Stages Secrets

The repo's first real activation expects the target host to already have:

- `/var/lib/nixbot/.ssh/id_ed25519`
- `/var/lib/nixbot/.age/identity`

`pkgs/ext/gcp-vms/nixify-vm.sh` decrypts the configured repo secrets locally and
passes them to `nixos-anywhere` via `--extra-files`, so the first boot can
already satisfy agenix activation and later `nixbot` deploys.

## Execution Plan

1. Create only the bootstrap VM when you want to inspect it first.

```bash
pkgs/ext/gcp-vms/create-vm.sh \
  --name gap3-gce-test-1 \
  --zone us-central1-a \
  --ensure-ssh-fw \
  --ensure-observability-fw \
  --ensure-postgres-fw \
  --ensure-nats-fw
```

Use the max Google Compute Engine Free Tier shape when the VM should stay inside
the always-free instance envelope:

```bash
pkgs/ext/gcp-vms/create-vm.sh \
  --name abird-mx1 \
  --free-tier-max \
  --ensure-ssh-fw
```

1. Nixify the VM.

```bash
pkgs/ext/gcp-vms/nixify-vm.sh \
  --name gap3-gce-test-1
```

By default `--name` is both the GCE instance name and the repo flake host name.
Use `--host <flake-host>` only when those differ. If the target already appears
to be NixOS, `nixify-vm.sh` exits successfully with a note. Use `--force` to run
`nixos-anywhere` again through the repo deploy identity; the script does not
delete or detach non-boot GCP disks.

If the VM should become a clean generic NixOS host and does not have a repo host
yet, use generic mode:

```bash
pkgs/ext/gcp-vms/nixify-vm.sh \
  --name abird-edge-1 \
  --generic
```

Generic mode generates a temporary minimal NixOS 25.11 flake, enables OpenSSH
for the bootstrap user/key, resolves the bootstrap VM's current root disk, and
uses `nixos-anywhere` to repartition that boot disk. It skips repo host
validation, `hosts/nixbot.nix`, and agenix/deploy-key staging. Use
`--generic-disk-device <path>` only when the inferred bootstrap root disk is not
the intended install target. The generated config imports NixOS's Google Compute
Engine guest config so serial console output, GCE networking defaults, and the
Google guest agent are present after reboot. The generated bootstrap user gets
an explicit Bash login shell and an unknown random password hash, while SSH
password and keyboard-interactive login remain disabled. Generic-mode sshd also
disables PAM because the bootstrap contract is local key-only access, and PAM
account/session handling on this minimal generated host can drop the connection
after public-key signature validation.

On free-tier-sized VMs, `nixos-anywhere` may otherwise OOM while loading the
temporary kexec installer. `nixify-vm.sh` therefore defaults to
`--bootstrap-swap-gb -1`, which auto-creates `/swapfile-nixos-anywhere` before
kexec only when physical RAM is below `--bootstrap-swap-min-mib`. The default
threshold is 4096 MiB. Auto mode sizes swap to bring RAM + swap up to that
threshold, with a 2 GiB minimum. Use `--bootstrap-swap-gb 0` to disable, or a
positive `--bootstrap-swap-gb <gb>` to force a specific size.

The kexec installer on free-tier-sized VMs can also wedge while substituting the
full disko dependency closure into the temporary installer store. When
`create-vm.sh --free-tier-max --nix --generic` runs the generic handoff, it
automatically passes `--build-on local`, `--no-disko-deps`, and
`--no-substitute-on-destination` to `nixify-vm.sh`. This keeps dependency
substitution out of the tiny installer environment and uploads only the disko
script for partitioning.

1. Or do the whole flow in one shot.

```bash
pkgs/ext/gcp-vms/create-vm.sh \
  --name gap3-gce-test-1 \
  --nix \
  --zone us-central1-a \
  --ensure-ssh-fw \
  --ensure-observability-fw \
  --ensure-postgres-fw \
  --ensure-nats-fw
```

For a repo-defined Free Tier VM, create the GCP instance and install the repo
host directly:

```bash
pkgs/ext/gcp-vms/create-vm.sh \
  --name gce-edge-1 \
  --free-tier-max \
  --nix \
  --ensure-ssh-fw \
  --ensure-wireguard-fw \
  --ensure-smtp-fw \
  --drop-ssh-fw-after
```

Use `--host <flake-host>` only if the GCE instance name and repo host name
differ. Repo-mode `--free-tier-max --nix` uses the same local-build,
minimal-disko-copy handoff as generic mode so the tiny installer environment
does not need to substitute large dependency closures.

By default, leave external IP allocation to GCP. `create-vm.sh` discovers the
generated IP after instance creation and passes it to `nixify-vm.sh` as
`--target-host`, so the direct repo-defined install does not need a temporary
generic NixOS pass or a manually configured IP address. For an edge host where
public SSH is only a bootstrap path, `--drop-ssh-fw-after` verifies the
configured nixbot deploy route, removes the public SSH tag from the GCP
instance, and deletes the SSH fw rule if no instance still uses it.

1. After nixify, continue with the normal deploy path.
   - Run `./scripts/nixbot.sh deploy --hosts <host>` for the next steady-state
     reconcile.
   - If `hosts/nixbot.nix` points at DNS or Tailscale instead of the bootstrap
     IP, finish that routing before depending on later deploys.

1. Delete an ad hoc VM and the bootstrap resources this tooling can create.

```bash
pkgs/ext/gcp-vms/delete-vm.sh \
  --name abird-mx1
```

Delete uses `--keep-disk=none` by default. Use `--keep-disk=boot` to preserve
the boot disk, or `--keep-disk=<disk>,boot` to preserve named disks plus the
boot disk. Use `--keep-fw-rules` to preserve fw rules.

## Script Roles

- `pkgs/ext/gcp-vms/create-vm.sh`
  - creates a Debian bootstrap VM
  - enables GCP IP forwarding by default
  - injects the bootstrap SSH public key through instance metadata
  - can pass a cloud-init user-data file through GCE metadata with
    `--init <path>`
  - waits for SSH to come up
  - preflights repo host evaluation and takeover metadata before GCP mutation
    when used with `--nix` in repo mode
  - can create subnet-scoped observability, Postgres, and NATS fw rules using
    the VM subnet CIDR as the ingress source range
  - can create public protocol-scoped fw rules and automatically add their
    target tags to the VM with `--ensure-wireguard-fw` and `--ensure-smtp-fw`
  - can run `nixify-vm.sh` immediately after creation with `--nix`
  - can remove bootstrap public SSH after repo-mode `--nix` with
    `--drop-ssh-fw-after`
- `pkgs/ext/gcp-vms/nixify-vm.sh`
  - resolves the VM by GCE instance name when `--target-host` is omitted
  - defaults the repo flake host to the instance name
  - supports `--generic` for a generated minimal NixOS 25.11 install when no
    repo host exists yet
  - creates temporary bootstrap swap on low-memory hosts before kexec
  - can pass `--no-disko-deps`, `--no-substitute-on-destination`, and
    `--no-use-machine-substituters` through to `nixos-anywhere`
  - no-ops when steady-state SSH shows the target is already NixOS
  - reruns `nixos-anywhere` when `--force` is given
  - validates `.#nixosConfigurations.<host>`
  - validates `hosts/nixbot.nix` takeover metadata
  - stages the repo deploy key and machine age identity
  - runs `nixos-anywhere`
  - verifies steady-state SSH with the repo deploy key
- `pkgs/ext/gcp-vms/delete-vm.sh`
  - deletes an ad hoc VM
  - auto-discovers the VM zone when `--zone` is omitted
  - deletes attached disks unless they match `--keep-disk=<csv>`
  - deletes the optional SSH, observability, Postgres, NATS, WireGuard, and SMTP
    fw rules only when their target tag is not still used by another instance
  - does not delete networks, subnets, or reserved external addresses because
    `create-vm.sh` only references those resources

## Current Defaults

The bootstrap VM defaults are centralized in `pkgs/ext/gcp-vms/common.sh`:

- project: `pvl-net`
- region: `asia-southeast1`
- zone: `asia-southeast1-a`
- network / subnet: `default`
- machine type: `n2d-standard-2`
- image project / family: `debian-cloud` / `debian-13`
- disk: `200GB pd-ssd`
- GCP IP forwarding: enabled
- tag: `ssh`
- SSH fw rule: `allow-ssh`
- observability fw rule: `allow-observability-subnet`
- Postgres fw rule: `allow-postgres-subnet`
- NATS fw rule: `allow-nats-subnet`
- WireGuard fw rule/tag: `allow-wireguard` / `allow-wireguard`, `udp:51820`
- SMTP fw rule/tag: `allow-smtp` / `allow-smtp`, `tcp:25`
- subnet-scoped observability ports: `6000,6001,6002`
- subnet-scoped Postgres ports: `5432`
- subnet-scoped NATS ports: `4222,7422`
- bootstrap kexec swap: auto when physical RAM is below `4096 MiB`

The script defaults to the `pvl-net` project's auto-created `default` VPC. It
does not discover a network from Terraform. To use the Terraform-managed
`gap3-dev-tf1` project in `tf/gcp-platform`, pass
`--project gap3-dev-tf1
--network main --subnet main` explicitly. If the target
project has no suitable VPC, create/manage one first or add that project to the
repo's GCP Terraform phase before using the bootstrap script.

For free-tier-sized bootstrap hosts, pass `--free-tier-max` to `create-vm.sh`.
The preset uses the current maximum Compute Engine Free Tier shape:

- zone: `us-central1-a` by default, within the supported Compute Engine Free
  Tier regions: `us-west1`, `us-central1`, or `us-east1`
- machine type: `e2-micro`
- image project / family: `debian-cloud` / `debian-13`
- disk: up to `30GB pd-standard`

The free-tier mode is guarded. Later or earlier explicit `--zone`,
`--machine-type`, `--image-project`, `--image-family`, `--disk-size-gb`, or
`--disk-type` arguments are accepted only if they remain inside the free-tier
contract. Non-free zones, larger disks, non-standard disks, non-`e2-micro`
machine types, or non-preset images fail before GCP mutation.

For `--free-tier-max --nix`, `create-vm.sh` also makes the `nixos-anywhere`
handoff free-tier-safe by forcing local builds and disabling remote destination
substitution for the installer copy.

## Failure Boundaries

- If the host does not exist in `hosts/nixbot.nix`, nixify stops before GCP
  mutation.
- If the repo secrets cannot be decrypted locally, nixify stops before
  `nixos-anywhere`.
- If post-install steady-state SSH does not come up, the VM is left intact for
  debugging.

# NixOS LXC Runtime System Links Upstream Plan

## Goal

Prepare an upstream NixOS/nixpkgs draft PR that fixes LXC containers losing
NixOS runtime system links under `/run`, without relying on local tmpfiles
workarounds or rerunning activation. Also track the adjacent LXC
special-filesystem ownership issue: generic NixOS still declares API/runtime
mounts that LXC/Incus and container systemd already provide.

Primary upstream issue:

- <https://github.com/NixOS/nixpkgs/issues/529888>

Related context:

- <https://github.com/nix-community/nixos-generators/issues/319>
- <https://github.com/NixOS/nixpkgs/pull/328682>
- <https://github.com/lxc/lxc-ci/issues/786>
- <https://discourse.nixos.org/t/lxd-distrobuilder-support-for-nixos/21375>

## Local Evidence

Local failure chain in `/home/pvl/src/nix`:

1. NixOS LXC stage-2 creates `/run/current-system` before execing systemd.
2. In Incus/LXC, systemd establishes the tmpfs-backed `/run` after that point.
3. That hides the activation-created `/run/current-system` and
   `/run/booted-system` links.
4. Distrobuilder's generated `systemd-udev-trigger.service` drop-in calls
   `/run/current-system/sw/bin/udevadm`.
5. Missing link causes `systemd-udev-trigger.service` to fail with
   `status=203/EXEC`.
6. `eth0` lacks `ID_NET_DRIVER` and `ID_NET_LINK_FILE`.
7. `systemd-networkd` shows `Network File: n/a`, `SETUP=pending`, and never
   starts DHCP.

The local repo previously had a workaround equivalent to:

```nix
systemd.tmpfiles.rules = [
  "L+ /run/current-system - - - - /nix/var/nix/profiles/system"
];
```

That workaround was not the right fix:

- It points early boot identity at `/nix/var/nix/profiles/system`, but that
  profile is produced by `register-nix-paths.service` from
  `/run/current-system`.
- It uses mutable profile state instead of the exact booted toplevel.
- It runs too late for generator-created early sysinit consumers.
- A local variant also reran NixOS activation manually, which fights upstream
  stage-2 semantics.

Current local fix:

- `lib/profiles/incus-lxc.nix` defines
  `nixos-container-runtime-system-links.service`.
- It runs before `register-nix-paths.service`, `systemd-tmpfiles-setup.service`,
  `systemd-udev-trigger.service`, and `systemd-networkd.service`.
- It derives the exact booted toplevel from `/sbin/init`'s embedded
  `systemConfig=...`.
- It restores `/run/current-system` and `/run/booted-system`.
- It does not rerun activation.
- It does not link through `/nix/var/nix/profiles/system`.

Local validation:

```sh
./scripts/nixbot.sh deploy --dirty-staged --hosts=pvl-vlab,pvl-vlab-1,pvl-vk,pvl-vk-1
```

Result:

- `pvl-x2`, `pvl-vlab`, `pvl-vlab-1`, `pvl-vk`, and `pvl-vk-1` deployed.
- `systemd-networkd` matched `eth0` to `/etc/systemd/network/10-eth0.network`.
- DHCP assigned expected addresses.
- `systemd-udev-trigger.service` result was successful despite ignored
  inaccessible host sysfs paths in unprivileged containers.

Adjacent special-filesystem finding:

- Upstream `nixos/modules/tasks/filesystems.nix` declares generic
  `boot.specialFileSystems` entries such as `/proc`, `/run`, `/dev`, `/dev/shm`,
  `/dev/pts`, and `/run/keys`.
- `virtualisation/lxc-container.nix` sets `boot.isContainer = true`, but it is
  not `boot.isNspawnContainer`, so those generic special filesystems remain
  declared for LXC.
- Incus/LXC already owns `/dev` as a minimal tmpfs device namespace and `/proc`
  as procfs plus LXCFS bind mounts. Container systemd owns tmpfs `/run` during
  early PID1 startup.
- Live Incus validation showed `boot.specialFileSystems` can evaluate to `{}`,
  while the guest still has `/dev tmpfs`, `/proc proc`, `/dev/pts devpts`,
  `/dev/shm tmpfs`, and `/run tmpfs`.
- No guest `.mount` units for `dev.mount`, `proc.mount`, `run.mount`,
  `dev-pts.mount`, `dev-shm.mount`, or `run-keys.mount` were needed.
- Local Incus profile now treats this as a whole-boundary override:
  `boot.specialFileSystems = lib.mkForce {};`.

## Upstream Diagnosis

Current upstream `virtualisation/lxc-container.nix`:

- Registers Nix store paths with `register-nix-paths.service`.
- Sets `/nix/var/nix/profiles/system` from `/run/current-system`.
- Adds `systemd-udev-trigger.service` back because networkd needs udev coldplug.
- Builds image with `config.system.build.toplevel/init` at `/sbin/init`.

Current upstream `pkgs/by-name/di/distrobuilder/nixos-generator.patch`:

- Uses `/run/current-system/sw/lib/systemd/systemd` to get systemd version.
- Writes a udev-trigger drop-in that executes
  `/run/current-system/sw/bin/udevadm`.
- Writes a console getty override using `/run/current-system/sw/bin/agetty`.

This means the generator and early generated units assume `/run/current-system`
exists before they run. That assumption is normally true from NixOS stage-2, but
fails when LXC/systemd runtime setup hides `/run` after activation.

## Proposed Upstream Shape

Patch should have two coordinated parts.

### 1. Make Distrobuilder Generator Independent Of `/run/current-system`

Files:

- `pkgs/by-name/di/distrobuilder/generator.nix`
- `pkgs/by-name/di/distrobuilder/nixos-generator.patch`

Plan:

- Add generator wrapper dependencies for commands it emits or invokes:
  `systemd`, `util-linux`, and existing core tools.
- Resolve tools from wrapped `PATH` with `command -v`.
- Use store paths in generated runtime drop-ins.
- Stop reading `/run/current-system/sw/lib/systemd/systemd` inside the
  generator.

Expected patch shape:

```sh
systemd="$(command -v systemd)"
udev="$(command -v udevadm)"
agetty="$(command -v agetty)"

SYSTEMD="$("$systemd" --version | head -n1 | cut -d' ' -f2 | cut -d'~' -f1)"
```

Generated drop-ins should use `$udev` and `$agetty`, which resolve to Nix store
paths via the wrapper.

Reason:

- A systemd service cannot fix generator-time assumptions.
- NixOS generator behavior should be deterministic from the Nix closure, not
  from mutable `/run` state.

### 2. Restore NixOS Runtime Links Before Sysinit Consumers

File:

- `nixos/modules/virtualisation/lxc-container.nix`

Plan:

- Add an early oneshot service, probably named
  `nixos-container-runtime-system-links.service`.
- `wantedBy = [ "sysinit.target" ];`
- `DefaultDependencies = false`.
- Run before:
  - `register-nix-paths.service`
  - `systemd-tmpfiles-setup.service`
  - `systemd-udev-trigger.service`
  - `systemd-networkd.service`
- Derive toplevel from `/sbin/init`:

```sh
system_config="$(sed -n 's/^systemConfig=//p' /sbin/init | head -n1)"
test -n "$system_config"
test -e "$system_config"
ln -sfn "$system_config" /run/current-system
ln -sfn "$system_config" /run/booted-system
```

Reason:

- `/sbin/init` is already the booted NixOS toplevel init script in LXC images.
- The embedded `systemConfig` is exact boot identity.
- `register-nix-paths.service` can still create the mutable system profile from
  the restored runtime link.
- No activation rerun needed.

### 3. Decide LXC Ownership Of Generic Special Filesystems

File:

- `nixos/modules/virtualisation/lxc-container.nix`

Question for upstream:

- Should LXC, like nspawn, suppress generic NixOS special filesystems because
  the runtime and container systemd own API mounts?

Candidate patch shape:

```nix
boot.specialFileSystems = lib.mkForce {};
```

or, if upstream wants narrower scope, suppress only API/runtime mounts inherited
from `tasks/filesystems.nix`:

- `/dev`
- `/dev/pts`
- `/dev/shm`
- `/proc`
- `/run`
- `/run/keys`

Reason:

- LXC images only need empty root-level directories such as `/dev`, `/proc`,
  `/sys`, and executable `/sbin/init`; the runtime supplies actual API mounts.
- Incus documents `/dev` as an ephemeral tmpfs populated with the allowed device
  nodes, and documents `/proc`, `/sys`, and LXCFS bind mounts as runtime setup.
- Unprivileged LXC guests cannot reliably remount runtime API filesystems.
- Treating these mounts as runtime-owned is cleaner than keeping per-path local
  disables in every LXC image profile.

Open review point:

- `systemd` itself also creates some API mounts such as `/run`, so upstream
  should decide whether this belongs in `lxc-container.nix` or in a broader
  container-filesystem policy shared with other non-nspawn runtimes.

## Test Plan

Add or extend NixOS test coverage for LXC/Incus/Proxmox-style containers.

Minimum assertions:

- `/run/current-system` exists after boot.
- `/run/booted-system` exists after boot.
- Both point to the `systemConfig` embedded in `/sbin/init`.
- `register-nix-paths.service` succeeds.
- `/nix/var/nix/profiles/system` exists after registration.
- `systemd-udev-trigger.service` does not fail with `203/EXEC`.
- `udevadm info /sys/class/net/eth0` includes `ID_NET_DRIVER` and
  `ID_NET_LINK_FILE`, when a veth is present.
- `networkctl status eth0` shows a real `.network` file, not
  `Network File:
  n/a`.
- DHCP on veth succeeds when `networking.useDHCP = true`.
- `config.boot.specialFileSystems` is empty or lacks runtime-owned API mounts
  for LXC, depending on chosen upstream shape.
- Booted guest still has working `/dev`, `/proc`, `/dev/pts`, `/dev/shm`, and
  `/run` mounts from LXC/systemd.

Regression scenario:

- Boot a generated LXC image.
- Run `nixos-rebuild boot`.
- Reboot container.
- Assert links, registration, `/etc` activation products, PAM files, udev, and
  networkd still work.

If Incus is available in upstream tests, use Incus. If not, start with existing
LXC/proxmox-lxc test harness and keep assertions runtime-agnostic.

## Draft Issue Comment

````markdown
I hit a very similar failure mode on NixOS LXC under Incus:
`/run/current-system` disappeared between stage-2 activation and early
systemd/sysinit consumers.

In our local config we previously used nearly the same workaround:

```nix
systemd.tmpfiles.rules = [
  "L+ /run/current-system - - - - /nix/var/nix/profiles/system"
];
```

That made boot limp forward, but I do not think it is correct:

1. `/nix/var/nix/profiles/system` is created by `register-nix-paths.service`
   from `/run/current-system`, so using it as the early source reverses the
   dependency direction.
2. The profile is mutable state, not necessarily the exact booted toplevel.
3. tmpfiles can be too late for early consumers. In our case distrobuilder's
   generated `systemd-udev-trigger` drop-in used
   `/run/current-system/sw/bin/udevadm`; when the link was missing, udev
   coldplug failed with `status=203/EXEC`, `eth0` never got `ID_NET_DRIVER` /
   `ID_NET_LINK_FILE`, and `systemd-networkd` left the interface pending with
   `Network File: n/a`.

What worked cleanly for us was restoring the NixOS runtime invariant from the
booted init itself:

- parse `systemConfig=...` from `/sbin/init`
- link `/run/current-system` and `/run/booted-system` to that exact store path
- run this before `register-nix-paths.service`, `systemd-udev-trigger.service`,
  `systemd-networkd.service`, and tmpfiles
- do not rerun activation, and do not point at `/nix/var/nix/profiles/system`

Local shape:

```nix
systemd.services.nixos-container-runtime-system-links = {
  wantedBy = [ "sysinit.target" ];
  before = [
    "register-nix-paths.service"
    "systemd-tmpfiles-setup.service"
    "systemd-udev-trigger.service"
    "systemd-networkd.service"
  ];
  unitConfig.DefaultDependencies = false;
  serviceConfig.Type = "oneshot";
  script = ''
    system_config="$(sed -n 's/^systemConfig=//p' /sbin/init | head -n1)"
    test -n "$system_config" -a -e "$system_config"

    ln -sfn "$system_config" /run/current-system
    ln -sfn "$system_config" /run/booted-system
  '';
};
```

This fixed first boot and post-recreate deploys for nested Incus LXC guests,
including DHCP/networkd coming up normally.

For upstream, I think this should be fixed in
`virtualisation/lxc-container.nix`, but likely paired with a small distrobuilder
generator fix: the generator itself currently references `/run/current-system`
while generating early runtime drop-ins, so it should use Nix-store paths
supplied by its wrapper/package instead of requiring `/run/current-system`
before any unit can restore it.

There is an adjacent upstream cleanup worth considering in the same area:
generic NixOS still declares `boot.specialFileSystems` for `/dev`, `/proc`,
`/run`, `/dev/pts`, `/dev/shm`, and `/run/keys` in LXC. In Incus those are
runtime/API mounts: Incus/LXC provides `/dev` and `/proc`, and container systemd
provides `/run`. Locally the clean Incus profile shape is now:

```nix
boot.specialFileSystems = lib.mkForce {};
```

That avoids per-path remount workarounds and matches the LXC runtime ownership
boundary. It may deserve a separate PR if reviewers want to keep the
`/run/current-system` fix narrowly scoped.
````

## Draft PR Description

Title:

```text
nixos/lxc: restore runtime system links before sysinit
```

Body:

```markdown
## Description

LXC containers can lose the activation-created `/run/current-system` and
`/run/booted-system` links when container systemd establishes the runtime `/run`
after NixOS stage-2 activation.

That breaks early sysinit consumers. In particular, the NixOS-patched
distrobuilder generator currently emits runtime drop-ins that call tools through
`/run/current-system`. If the link is missing, `systemd-udev-trigger` can fail
with `status=203/EXEC`; then veth coldplug does not complete, networkd does not
match the interface to a `.network` file, and DHCP never starts.

Fix this in two places:

- make the distrobuilder generator use store paths from its wrapper instead of
  `/run/current-system` while generating early drop-ins
- restore `/run/current-system` and `/run/booted-system` from `/sbin/init`'s
  embedded `systemConfig` before sysinit services consume those links

Also consider a follow-up, or separate PR, for LXC special-filesystem ownership:
generic NixOS declares API mounts such as `/dev`, `/proc`, and `/run`, but LXC
and container systemd already provide them at runtime.

This keeps the mutable `/nix/var/nix/profiles/system` profile as the output of
`register-nix-paths.service`; it is not used as early boot identity.

Fixes #529888. Related: nix-community/nixos-generators#319, #328682,
lxc/lxc-ci#786.

## Testing

- build LXC image
- boot LXC/Incus container
- verify `/run/current-system` and `/run/booted-system`
- verify `register-nix-paths.service`
- verify `systemd-udev-trigger.service`
- verify `networkctl status eth0` has a real `.network` file and DHCP address
- reboot after `nixos-rebuild boot`
```

## Execution Checklist

1. Create nixpkgs branch.
2. Patch `generator.nix` wrapper inputs.
3. Patch `nixos-generator.patch` to remove `/run/current-system` generator
   dependencies.
4. Patch `lxc-container.nix` with early runtime-link restore service.
5. Decide whether to include `boot.specialFileSystems = lib.mkForce {};` in the
   same PR or split it to a follow-up.
6. Add test assertions.
7. Run Nix formatting.
8. Build affected package:

```sh
nix build .#distrobuilder.generator
```

9. Build LXC image:

```sh
nix build .#nixosConfigurations.<test-lxc>.config.system.build.tarball
```

10. Run NixOS tests for LXC/Incus if present.
11. Open draft PR with links above.
12. Post issue comment linking draft PR.

## Handoff Notes

- Do not propose `/run/current-system -> /nix/var/nix/profiles/system` as final
  fix.
- Do not run NixOS activation from a local service.
- Do not remove `systemd-udev-trigger.service`; upstream explicitly re-adds it
  because networkd needs coldplug in LXC.
- Do not treat `/dev`, `/proc`, or `/run` as guest-owned filesystems in Incus
  LXC; they are runtime/API mounts.
- Prefer a whole-boundary special-filesystem policy for LXC over maintaining a
  local denylist of pseudo-filesystems.
- Keep distrobuilder generator writes limited to `/run/systemd/...`; avoid
  writing `/etc`.
- If reviewers object to adding a unit in `lxc-container.nix`, ask where NixOS
  should restore stage-2 runtime invariants after LXC/systemd creates `/run`.
- If reviewers prefer generator-only fix, note it fixes generator-time
  `/run/current-system` assumptions but not issue #529888's broader missing
  runtime links.

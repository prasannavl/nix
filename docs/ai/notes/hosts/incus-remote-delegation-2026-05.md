# Incus Remote Delegation 2026-05

`services.incusMachines.remote` lets a NixOS host run the repo Incus lifecycle
helpers against a remote Incus HTTPS API instead of a local daemon.

The remote mode is intended for delegated control from an Incus guest back to
its parent daemon:

- the real parent host owns Incus preseed, networks, profiles, storage, and
  trusted certificates
- the delegated guest gets only an Incus client certificate and private key
- helper commands build an ephemeral Incus client config under `/run`
- lifecycle, image, reconcile, and settle commands target the configured remote
  name through normal Incus CLI remote references
- remote-mode GC is disabled because the delegated host cannot distinguish its
  own declared children from sibling or parent-managed containers on the same
  remote daemon
- local Incus daemon enablement defaults off in remote mode
- host suspend handling remains local-only

`pvl-x2` is the first concrete consumer. It creates `pvl-vlab-1` on `incusbr0`
at `10.10.20.30` and forwards the parent Incus HTTPS API to `127.0.0.1:8443`
inside that guest using an Incus proxy device. The delegated host should not
import parent-host-specific files; it only needs the remote API URL, project,
certificate material, and the instance addresses it is allowed to declare.
`pvl-x2` trusts the public `pvl-vlab-1` client certificate, restricted to the
`pvl` project. That project is restricted, uses the dedicated `ipvlbr0` bridge,
allows only managed disk devices on the `default` storage pool, and explicitly
allows nested containers for the delegated `pvl` machines. `pvl-vk-1` remains
unprivileged; the NixOS Incus guest profile disables activation-time remounts of
container-manager-owned special filesystems instead of widening the Incus
project to allow privileged containers.

`pvl-x2` mirrors the `pvl-a1` tenant project shape but uses subnets chosen to
avoid likely home LAN overlap:

- `abird`: `iabirdbr0` on `10.10.100.1/24`
- `abird-dev`: `iabirddevbr0` on `10.10.200.1/24`
- `pvl`: `ipvlbr0` on `10.10.50.1/24`

`pvl-vlab-1` imports `../../lib/incus`, but its `services.incusMachines.remote`
points at `https://127.0.0.1:8443` and uses the agenix-managed
`data/secrets/incus/pvl-vlab-1.key.age` private key. Its
`remote.allowedSubnets = [ "10.10.50.0/24" ]` setting is a local validation
guard: declared child instance addresses must remain inside the delegated
subnet, but addresses are still written explicitly. It declares `pvl-vk-1` at
`10.10.50.31`; that instance is created on the `pvl-x2` Incus daemon, not in a
nested Incus daemon inside `pvl-vlab-1`.

Raw `incus query` calls against a remote must include `?project=pvl`; relying
only on the Incus remote config's project field caused readiness settlement to
query `default` and report `pvl-vk-1` as missing even while it existed in the
`pvl` project.

`pvl-vk-1` is a direct child of `pvl-x2`. It uses `security.privileged = false`
plus `security.nesting = true`. The first unprivileged attempts failed NixOS
activation while remounting special filesystems such as `/dev`, `/proc`, `/run`,
and `/run/keys` with `fsconfig() failed: Function not implemented`. Mount
syscall interception, including the mount-shift variant, was not enough in this
environment. The shared `lib/profiles/systemd-container.nix` profile now
disables those activation remounts because Incus/LXC already owns those mounts
for the guest.

Final delegated deploy fixes:

- `pvl` project restrictions now explicitly block container syscall interception
  and low-level container keys, and allow only unprivileged containers. Existing
  stale `security.syscalls.intercept.*` instance keys must be removed before
  tightening the project, otherwise Incus rejects the project update. The shared
  `services.incusMachines.preseedMigrations` hook now runs that cleanup before
  `incus-preseed` for declared preseed projects, keeping the migration out of
  host-local systemd overrides.
- The settlement helper no longer assumes `true` exists in `/bin`; it probes the
  NixOS profile path first. It also makes one best-effort networkd
  reconciliation attempt when an instance is running and accepts exec but has
  not reported the expected IPv4 yet.
- Fresh container boots need `/run/current-system` before the LXC distrobuilder
  udev coldplug override runs. Tmpfiles creates that link too late, so
  `systemd-container` now creates it with an early sysinit oneshot before
  `systemd-udev-trigger` and `systemd-networkd`. Without this,
  `systemd-udev-trigger` exits `203/EXEC`, networkd leaves `eth0` with
  `Network File: n/a`, and the guest never reports `10.10.50.31`.

Validation on 2026-05-15:
`./scripts/nixbot.sh deploy --dirty-staged
--hosts=pvl-vk-1` succeeded for
`pvl-x2`, `pvl-vlab-1`, and `pvl-vk-1` with no rollback. Live checks after
deploy showed `restricted.containers.interception =
block`, no stale
`security.syscalls.intercept.mount` key on `pvl-vk-1`, and `pvl-vk-1` running
with `10.10.50.31` on `eth0`.

The first deploy attempt exposed the GC boundary: `pvl-vlab-1` connected to the
parent daemon, saw `pvl-vlab`, `gap3-gondor`, and its own outer `pvl-vlab-1`
container as `user.managed-by=nixos` but not declared by the delegated host, and
stopped/deleted them. Remote mode therefore must not run
`incus-machines-gc.service` until ownership metadata is scoped per controller.

The private delegated client key is not stored in the Nix store. Only the public
certificate is imported directly from the repo. `acceptCertificate =
true` is
used for the first version because the parent Incus server certificate is not
yet pinned in the repo; switch to `serverCertificateFile` when that certificate
is made declarative.

Tenant-managed access to parent projects uses parent-validated desired-state
files instead of native Incus trust-store delegation. `pvl-x2` creates one
`/var/lib/incus-delegations/<name>/certs.json` file per named delegation and
bind-mounts selected delegation directories into tenant machines under
`/var/lib/incus-delegation/<name>`. The guest owns the file content. The parent
watches and reconciles each file through the named
`services.incusMachines.certificateDelegations.<name>` resource; each
`incusLib.mkCertDelegation "<name>"` disk device only references and mounts that
resource into the guest.

The tenant file is JSON data, not Nix code. Parent validation requires a bounded
certificate count, safe tenant-local names, and valid PEM certificate material.
The target project comes only from the parent Nix config, not the tenant file.
The parent always creates Incus trust entries as `type = client`,
`restricted = true`, and `projects = [ <delegation.project> ]`, with a forced
delegation-specific name prefix. Removal only follows the parent-owned
delegation state file, so the delegated path cannot remove parent-owned certs
such as the unrestricted `pvl` cert.

Current delegated resources:

- `pvl`: mounted into `pvl-vlab-1` as `delegated-certs`
- `abird`: mounted into `abird-nest` as `delegated-certs`
- `abird-dev`: mounted into `abird-nest` as `delegated-dev-certs`

`pvl-vlab-1` bootstraps its own parent access by declaring
`services.incusMachines.remote.certificateDelegation.enable = true`. The shared
Incus module derives the mounted tenant file from the remote project by default,
writes the guest's public client certificate to
`/var/lib/incus-delegation/pvl/certs.json`, waits until the parent Incus API
accepts that delegated cert, and makes that step an explicit prerequisite of
`incus-images.service`. The guest config only owns the remote endpoint and
client certificate/key. If the guest declares no Incus resources, the module
does not create the delegation writer service, so the absence of the mounted
delegation file does not block activation. This keeps the direct parent trust
store limited to the unrestricted `pvl` cert while still letting `pvl-vlab-1`
manage the parent `pvl` project declaratively.

`abird-nest` is declared in the parent Incus `abird` project at `10.10.100.31`.
Per-instance project placement is handled by
`services.incusMachines.instances.<name>.project`; lifecycle commands pass that
project through to the Incus CLI/API. Because `abird-nest` needs the parent API
proxy and host-path delegation mounts, the restricted `abird` project explicitly
allows proxy devices and restricts host-path disk sources to the `abird` and
`abird-dev` delegation directories.

Incus CLI `query` must not go through the project-wrapped command helper:
`incus query` rejects the global `--project` flag. Project-aware queries should
use plain `incus query` with `project=<name>` encoded in the query URL; mutating
lifecycle/config/storage commands should keep using the project-wrapped helper.
Timed Incus commands must not invoke shell functions directly through `timeout`;
wrap the real `incus --project <project> ...` command instead.

Removing the named `certificateDelegations.<name>` resource is the deletion
boundary. The parent-side GC compares current delegations with the last applied
delegation state, removes previously managed trust entries for deleted
delegations, and removes the delegation directory when it is under
`/var/lib/incus-delegations/`.

Tenant JSON entries use `data` for the public PEM payload:

```json
{
  "version": 1,
  "certificates": [
    {
      "name": "alice-laptop",
      "data": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"
    }
  ]
}
```

Source of truth files:

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `hosts/pvl-x2/incus.nix`
- `hosts/pvl-vlab-1/incus.nix`
- `data/secrets/incus/pvl-vlab-1.crt`
- `data/secrets/incus/pvl-vlab-1.key.age`

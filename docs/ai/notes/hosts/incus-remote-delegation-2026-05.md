# Incus Remote Delegation 2026-05

`services.incusMachines.global.remote` lets a NixOS host run the repo Incus
lifecycle helpers against a remote Incus HTTPS API instead of a local daemon.

The remote mode is intended for delegated control from an Incus guest back to
its parent daemon:

- the real parent host owns Incus preseed, networks, profiles, storage, and
  trusted certificates
- the delegated guest gets only an Incus client certificate and private key
- helper commands build an ephemeral Incus client config under `/run`
- lifecycle, image, reconcile, and settle commands target the configured remote
  name through normal Incus CLI remote references
- remote-mode GC is enabled for delegated controllers, but scoped to configured
  remote projects and to instances tagged with the controller's
  `user.incus-machines.controller` owner marker
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

`pvl-vlab-1` imports `../../lib/incus`, but its
`services.incusMachines.global.remote` points at `https://127.0.0.1:8443` and
uses the agenix-managed `data/secrets/incus/pvl-vlab-1.key.age` private key. Its
`remote.projects.pvl.allowedSubnets = "10.10.50.0/24"` setting is a local
validation guard: declared child instance addresses in the `pvl` project must
remain inside the delegated subnet, but addresses are still written explicitly.
It declares `pvl-vk-1` at `10.10.50.31`; that instance is created on the
`pvl-x2` Incus daemon, not in a nested Incus daemon inside `pvl-vlab-1`.

Raw `incus query` calls against a remote must include `?project=pvl`; relying
only on the Incus remote config's project field caused readiness settlement to
query `default` and report `pvl-vk-1` as missing even while it existed in the
`pvl` project.

`pvl-vk-1` is a direct child of `pvl-x2`. It uses `security.privileged = false`
plus `security.nesting = true`. The first unprivileged attempts failed NixOS
activation while remounting special filesystems such as `/dev`, `/proc`, `/run`,
and `/run/keys` with `fsconfig() failed: Function not implemented`. Mount
syscall interception, including the mount-shift variant, was not enough in this
environment. The shared `lib/profiles/lxc.nix` profile now disables those
activation remounts because Incus/LXC already owns those mounts for the guest.

Final delegated deploy fixes:

- `pvl` project restrictions explicitly block container syscall interception and
  low-level container keys, and allow only unprivileged containers. Generic
  `services.incusMachines.global.preseedMigrations` remains available for
  explicit future Incus fabric transitions, but the temporary default cleanup
  for stale `security.syscalls.intercept.*` keys was removed after the rollout
  completed successfully.
- The settlement helper no longer assumes `true` exists in `/bin`; it probes the
  NixOS profile path first. It also makes one best-effort networkd
  reconciliation attempt when an instance is running and accepts exec but has
  not reported the expected IPv4 yet.
- Fresh container boots need `/run/current-system` before the LXC distrobuilder
  udev coldplug override runs. Tmpfiles creates that link too late, so the LXC
  profile now creates it with an early sysinit oneshot before
  `systemd-udev-trigger` and `systemd-networkd`. Without this,
  `systemd-udev-trigger` exits `203/EXEC`, networkd leaves `eth0` with
  `Network File: n/a`, and the guest never reports `10.10.50.31`.
- NixOS container images start systemd directly, bypassing the normal stage-2
  activation path. The LXC profile runs `/run/current-system/activate` once
  during early sysinit with `NIXOS_ACTION=boot` after creating the
  `/run/current-system` link; this recreates runtime activation state such as
  `/run/agenix` after container restart or rollback before networked services
  try to consume secrets.
- Full delegated deploys can transiently report failed units while a parent
  guest is still reconciling a child guest. `nixbot` now retries the post-switch
  health gate for a bounded window before rolling the deployment back, while
  still failing if the same system/user unit or Podman health checks keep
  failing.

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
stopped/deleted them. Remote GC now lists only configured delegated projects and
requires both `user.managed-by=nixos` and
`user.incus-machines.controller=<controllerId>` before applying a removal
policy. The controller ID defaults to the NixOS host name and can be overridden
with `services.incusMachines.controllerId`.

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
`services.incusMachines.global.certificateDelegations.<name>` resource; each
`incusLib.mkCertDelegation "<name>"` disk device only references and mounts that
resource into the guest. The parent lifecycle maps guest root through each
guest's idmap, then applies host-side ownership to these handoff files. This
lets root-owned guest services update the delegation state while keeping the
mount compatible with restricted project source-path checks.

Incus trust entries are globally unique by certificate fingerprint, not by
project. If the same tenant certificate is published through multiple project
delegations, the parent reconciler must converge one trust entry whose
`projects` list contains all delegated projects. It must not delete and recreate
the same fingerprint for each project-specific service.

Incus images are also globally keyed by image fingerprint. If an import sees the
same fingerprint before the repo metadata properties are present, the image
reconciler should treat the existing fingerprint as the desired image and attach
the declared alias instead of failing the deploy. For split local NixOS images,
do not derive this from `sha256(metadata.tar.xz)`; reconcile by the metadata
properties Incus stores on the image and serialize aliases that share the same
declared image identity.

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

`pvl-vlab-1` bootstraps its own parent access through
`services.incusMachines.global.remote.projects.pvl`. The shared Incus module
auto-publishes the default remote project's client certificate to
`/var/lib/incus-delegation/pvl/certs.json`, waits until the parent Incus API
accepts that delegated cert, and makes that step an explicit prerequisite of
`incus-images.service`. Additional project-scoped delegated certificates can be
listed under `remote.projects.<project>.certs`; bare certificate paths derive
their tenant-local name from the file basename, stripping the project suffix
when present. The guest config only owns the remote endpoint, client
certificate/key, per-project allowed subnets, and optional delegated cert files.
This keeps the direct parent trust store limited to the unrestricted `pvl` cert
while still letting `pvl-vlab-1` manage the parent `pvl` project declaratively.

`abird-nest` is declared in the parent Incus `abird` project at `10.10.100.10`.
Per-instance project placement is handled by
`services.incusMachines.<project>.instances.<name>.project`; lifecycle commands
pass that project through to the Incus CLI/API. Because `abird-nest` needs the
parent API proxy and host-path delegation mounts, the restricted `abird` project
explicitly allows proxy devices and restricts host-path disk sources to the
`abird` and `abird-dev` delegation directories.

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

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
`default` project.

`pvl-vlab-1` imports `../../lib/incus`, but its `services.incusMachines.remote`
points at `https://127.0.0.1:8443` and uses the agenix-managed
`data/secrets/incus/pvl-vlab-1.key.age` private key. Its
`remote.allowedSubnets = [ "10.10.20.0/24" ]` setting is a local validation
guard: declared child instance addresses must remain inside the delegated
subnet, but addresses are still written explicitly. It declares `pvl-vk-1` at
`10.10.20.31`; that instance is created on the `pvl-x2` Incus daemon, not in a
nested Incus daemon inside `pvl-vlab-1`.

`pvl-vk-1` is a direct child of `pvl-x2`, but it follows the unprivileged
`pvl-vk` pattern from `pvl-vlab`: `security.nesting = true` plus Incus mount
syscall interception and shifted mounts. The first unprivileged attempt failed
NixOS activation while remounting special filesystems such as `/dev`, `/proc`,
and `/run` with `fsconfig() failed: Function not implemented`; the next least
privilege candidate is to keep it unprivileged and enable
`security.syscalls.intercept.mount` plus
`security.syscalls.intercept.mount.shift`.

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

Source of truth files:

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `hosts/pvl-x2/incus.nix`
- `hosts/pvl-vlab-1/incus.nix`
- `data/secrets/incus/pvl-vlab-1.crt`
- `data/secrets/incus/pvl-vlab-1.key.age`

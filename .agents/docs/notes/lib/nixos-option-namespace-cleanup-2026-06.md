# NixOS Option Namespace Cleanup

Repo-owned service option roots use kebab-case names that describe the control
plane they expose:

- `services.podman-compose`
- `services.systemd-user-manager`
- `services.incus-manager`
- `services.migration-manager`
- `services.active-sync`
- `services.nginx-proxy-vhosts`

Package-owned user services are top-level `user-services.<user>.<service>`. Do
not place these under `services.*`; they declare `systemd.user.services`
workloads, while `services.systemd-user-manager` is the system-level manager
that reconciles them.

Keep the local `x` namespace for host policy toggles, but use normal camelCase
inside it, such as `x.fdLimit`, `x.panicReboot`, and `x.sshDefault`.

Pure helper libraries should not be exposed as NixOS options. The disko helpers
live in `lib/disko/lib.nix` and host storage modules import them directly:

```nix
let
  diskoLib = import ../../lib/disko/lib.nix { lib = lib; };
in {
  disko.devices.disk.main = diskoLib.mkMain { ... };
}
```

`lib/disko/default.nix` remains the NixOS module that imports upstream disko and
host installer overrides. It should not define a `diskoLib` option.

# pvl-x2 Incus Project Routes

> The route API and general `forwardRules` guidance remain current. The Abird
> stage-era exception list below is historical; the fresh platform boundary is
> recorded in `pvl-x2-abird-platform-project-2026-07.md`.

## Context

`pvl-x2` still uses the live `gap3-gondor` path for migrated Abird services that
remain on `10.10.30.0/24`. During the staged Incus project and remote delegation
migration, the parent host needed to route traffic from the local Incus project
fabrics to that subnet through `gap3-gondor` at `10.10.20.20`.

The failed shape declared the route through
`networking.interfaces.incusbr0.ipv4.routes`. That route belonged to a bridge
created by Incus preseed, not to a NixOS-created interface, so
`network-addresses-incusbr0.service` could be inactive while the bridge existed.
The result was an apparently healthy Incus bridge with no host route to
`10.10.30.0/24`.

## Design Decision

Routes owned by Incus fabrics belong under the project that owns the fabric:
`services.incus-manager.<project>.routes`.

Do not make callers repeat the host bridge interface in normal project route
declarations. The module derives the host-side bridge from the project default
profile by requiring a unique NIC device with a `network` property. This keeps
the API tied to the Incus fabric model instead of to incidental device names
such as `eth0`.

The imperative apply/delete behavior belongs in `lib/incus/helper.sh`, not as
inline shell inside `lib/incus/default.nix`. Nix serializes desired route state
to JSON and wires systemd ordering; the helper reconciles kernel routes.

## Managed Fabric Forward Exceptions

Project-to-project forwarding policy is also owned by the Incus parent fabric.
Use `incusLib.mkManagedFabricPolicy.forwardRules` for narrow exceptions that
must not become broad `forwardTo` trust between whole projects.

`forwardRules` entries name the source fabric, target fabric, optional source
address, optional destination address or CIDR, and allowed TCP/UDP ports. The
helper renders these as explicit nft `accept` rules before the generated
project-to-project deny matrix. Return traffic is still handled by connection
tracking, so an exception grants only new flows in the declared direction.

For the current delegated Abird fabrics on `pvl-x2`, `abird-platform` may reach
the preserved Gondor DNS proxy at `10.10.30.20` on TCP/UDP 53 and the Gondor
Harmonia cache at `10.10.30.80` on TCP 5000 through the `default` fabric. It may
also reach TCP 22 across `10.10.220.0/24` in `abird-dev`, which lets Nest's
bounded-start settlement verify SSH readiness without granting broad fabric
trust. The clean empty `abird` fabric has no cross-project exceptions.

## Project-Qualified Readiness Selectors

When one Incus controller owns multiple projects with the same guest names,
readiness and reconcile selectors must resolve through the declared machine ID
or the `project/name` reference before calling `incus list`.

The delegated Abird project rollout exposed a shell gotcha in
`lib/incus/helper.sh`: parameter defaults such as `${VAR-{}}` append an extra
literal `}` when `VAR` is set. That corrupts JSON object maps like
`INCUS_MACHINES_INSTANCE_NAMES`, so `jq --argjson` fails and the helper falls
back to the raw selector.

Keep JSON-object defaults behind an explicit helper rather than inline parameter
expansion. The generated reconciler and settlement commands should also export
`INCUS_MACHINES_DECLARED_INSTANCE_REFS`, and selector resolution should accept
`project/name` refs so ambiguous bare names remain unresolved while explicit
project refs select the intended machine ID.

## Reconciler Semantics

`incus-machines-routes.service` is a local-only oneshot that runs after
`incus-preseed.service`, so Incus has created the bridge before `ip route`
touches it. Machines and image import wait for the route service only when
routes are declared.

The service must still exist on local Incus-managed hosts when the desired route
list is empty. That lets the helper compare the empty desired state against
`/var/lib/incus-machines/routes.json` and remove routes that this module
previously owned. Otherwise removing the final route from Nix would leave stale
kernel routes until reboot or manual cleanup.

The helper owns only routes recorded in its state file. It removes obsolete
owned routes and applies current routes with `ip -4 route replace` using
`proto static`, avoiding unrelated host route mutation.

### Incus restart coupling

The route unit must be `PartOf=incus.service` as well as ordered
`After=incus.service`. Incus can restart during a NixOS switch after
`sysinit-reactivation.target` has already run the route reconciler. Recreating
an Incus-managed bridge deletes host routes attached to that bridge; without
restart propagation, the oneshot remains active-exited and does not restore
them.

This occurred on `pvl-x2` on 2026-08-30: the route reconciler installed
`10.10.30.0/24` at 08:00:25, then Incus restarted at 08:00:27 and rebuilt
`incusbr0`. The missing route broke private DNS for `abird-nest`, so Nixbot
could neither fetch `ci.abird.internal` from the target nor use its local relay
fallback. Coupling the route unit to Incus makes the restart transaction stop
the reconciler before Incus and run it again after Incus is ready.

Restoring the route exposed a separate policy omission: DNS succeeded, but the
existing narrow forward exception did not permit the resolved cache endpoint.
Keep the `10.10.30.80:5000` exception alongside DNS; changing Nixbot to a
Tailscale hostname would bypass the declared fabric ownership instead of fixing
it.

## Validation Expectations

For `pvl-x2`, generated route JSON should resolve the default project route to:

```json
[
  {
    "address": "10.10.30.0",
    "interface": "incusbr0",
    "prefixLength": 24,
    "project": "default",
    "via": "10.10.20.20"
  }
]
```

For a local Incus-managed host with no routes, generated route JSON should be
`[]` and `incus-machines-routes.service` should still exist. This proves
final-route cleanup can run.

Use focused validation plus the repo lint gate:

```bash
alejandra lib/incus/default.nix hosts/pvl-x2/incus.nix
bash -n lib/incus/helper.sh
shellcheck lib/incus/helper.sh
nix build --no-link .#nixosConfigurations.pvl-x2.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.pvl-a1.config.system.build.toplevel
nix build --no-link .#checks.x86_64-linux.lib-incus-module
nix run .#lint -- --diff --base HEAD --system x86_64-linux
```

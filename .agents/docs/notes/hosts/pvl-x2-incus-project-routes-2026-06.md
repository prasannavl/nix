# pvl-x2 Incus Fabric Routing

## Ownership boundary

Abird assembles its authoritative fabric contract from the concrete stack
profiles under `lib/stacks`: stable IPv4 and IPv6 prefixes, fabric-local role
addresses, placements, lifecycle state, and logical allow edges. Pvl does not
import or evaluate the Abird repository. It owns a deliberately small accepted
projection directly in `hosts/pvl-x2/incus.nix`, beside the physical realization
that consumes it. The projection contains only the two address bases, four
subnet IDs, three referenced endpoint IDs, and six access edges required for
physical enforcement.

`lib/flake/fabric-projection.nix` validates that projection and generically
derives its families, `/24` and `/64` prefixes, endpoint addresses, and
family-specific forwarding rules. Keep provenance, schema versions, placement,
lifecycle state, complete role membership, and expanded values out of the Pvl
projection. Pvl remains independently evaluable and owns the physical
realization on `pvl-x2`: bridge names, the default and Pvl-only prefixes, routed
next hops, nftables rendering, source filtering, and perimeter NAT.

Changes to a shared subnet ID, endpoint ID, or access edge must update the Abird
contract and Pvl projection in one coordinated change. The duplication is an
intentional repository boundary, not a second complete topology model.

The generic projection test uses a small synthetic topology rather than
importing host data. Assertions in `hosts/pvl-x2/incus.nix` validate the real
embedded fabric set, Gondor prefixes, Nest endpoint, dual-family rule count, and
routed OAuth source identities during every host evaluation.

## Physical topology

The direct `abird-platform`, `abird`, and `abird-dev` fabrics are managed
bridges. Direct production remains standby and has no declared instances.
`abird-gondor` is a routed child of the default bridge through the `gap3-gondor`
guest.

The outer router NIC declares both Gondor prefixes with `ipv4.routes` and
`ipv6.routes`. Incus installs those host routes and includes the routed sources
in the NIC's source-filter allowance. Every managed outer and inner NIC has both
`security.ipv4_filtering` and `security.ipv6_filtering` enabled with fixed
addresses.

The old project-route option, helper command, state file, and systemd unit are
removed. Routes that belong to an inherited NIC are normal live-reconciled NIC
properties, not a parallel host-route subsystem.

## Dual-stack policy

Every managed fabric declares both families. The default and Pvl bridge ULAs
remain pinned to their existing prefixes; Abird uses its stable
`fd42:ab1d:ab1d::/48` allocation. All bridges have Incus IPv4 and IPv6 NAT
disabled. Stateful DHCPv6 makes fixed `ipv6.address` allocations deterministic.

The nftables policy classifies routed children by interface plus source or
destination prefix. Parent selectors explicitly exclude routed-child prefixes,
so routed traffic cannot fall through to the parent's policy in either family.
The outer default fabric retains its existing open management policy for
`pvl-vlab*`; Gondor is contained by the routed-child policy and therefore does
not inherit that openness. Essential ICMPv6 neighbor discovery, router
discovery, multicast-listener control, and path errors are admitted before
host-service policy; TCP, UDP, and echo traffic remain subject to the normal
boundary rules.

The application control plane remains IPv4-preferred: service discovery,
readiness, and nginx upstream selection do not switch families. IPv6 is still a
fully routed and filtered data-plane capability, including access to IPv6-only
Internet destinations.

## Perimeter NAT

Address translation is based on the internal destination boundary, not the
current output interface. Each private or ULA source prefix is masqueraded only
when the destination is outside the exact managed internal prefixes derived from
Pvl's physical configuration and minimal Abird projection.

Consequences:

- traffic among default, Pvl, platform, direct production, direct development,
  and Gondor preserves the individual guest source in both families;
- Gondor never collapses to the outer router address internally;
- Internet-bound IPv4 and ULA IPv6 traffic is translated once on `pvl-x2`;
- adding or renaming a managed bridge cannot silently change the NAT boundary.

`gap3-gondor` is a pure router and keeps both inner Incus NAT flags disabled. Do
not compensate at destinations by trusting `10.10.20.20` or its IPv6 peer as the
origin of all inner guests.

## Live reconciliation

`services.incus-manager.<project>.instances.<name>.network` owns an inherited
NIC's static addresses, routes, and source-filter properties. The manager uses
`incus config device override` and tracks only its property keys in
`user.nixos-meta.network.deviceProperties`. Removed owned properties are cleaned
while unrelated NIC properties are preserved.

Network-property changes are excluded from recreate hashes and lifecycle restart
triggers. They converge through the existing `incus-machines-limits`
live-property unit, whose public name remains stable for compatibility. Network
and limit reconcilers are forbidden from owning the same device property.

Remote project declarations use family-keyed `allowedSubnets`; evaluation checks
fixed IPv4 and IPv6 addresses independently. This keeps the delegated source
boundary symmetric instead of validating only the IPv4 half of a guest NIC.

## Rollout order

1. Land the Abird contract and matching Pvl enforcement projection coherently;
   each repository remains independently evaluable.
2. Deploy `pvl-x2` so return routes, dual-family filtering, perimeter NAT, and
   stable bridge prefixes exist together.
3. Deploy `gap3-gondor`, then `abird-nest` and `pvl-vlab-1`, to converge inner
   and remotely managed NICs.
4. Verify allowed and denied cross-fabric flows in both families plus IPv4-only
   and IPv6-only Internet egress.

This implementation has been built but not deployed. Do not describe live
systems as converged until those probes pass after rollout.

## Validation

```bash
nix build --no-link .#checks.x86_64-linux.lib-incus-module
nix build --no-link .#checks.x86_64-linux.lib-incus-helper
nix build --no-link .#checks.x86_64-linux.lib-flake-fabric-projection
nix build --no-link .#nixosConfigurations.pvl-x2.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.pvl-vlab-1.config.system.build.toplevel
```

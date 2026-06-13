# pvl Tailnet Reverse-Path Filtering

Date: 2026-06-12

## Symptom

From `pvl-l5`, direct tailnet IP traffic to `pvl-x2` timed out:

- `nc -vz 100.100.1.1 22`
- `ping 100.100.1.1`
- `curl http://100.100.1.1:47929/`

At the same time, `tailscale ping pvl-x2` returned a disco-layer pong. That only
proves Tailscale peer discovery and path negotiation; it does not prove ordinary
IP packets injected through `tailscale0` are accepted by both host OS stacks.

The same class of failure had also been seen from `pvl-a1`, so do not treat
`pvl-l5` as causal. The reverse direction worked: over the Cloudflare Access SSH
route to `pvl-x2`, `pvl-x2` could `ping 100.64.248.124` and open TCP/22 to
`pvl-l5`.

## Root Cause

`pvl-x2` uses the common NixOS networking profile with:

- `networking.nftables.enable = true`
- `networking.firewall.checkReversePath = true`
- `services.tailscale.useRoutingFeatures = "none"`

The generated NixOS nftables firewall uses a strict reverse-path filter:

```nft
chain rpfilter {
  type filter hook prerouting priority mangle + 10; policy drop;
  fib saddr . mark . iif oif exists accept
}
```

Tailscale installs policy rules around fwmark `0x80000`. On `pvl-x2`, the marked
route lookup for tailnet peer source addresses resolves through the LAN uplink
instead of `tailscale0`:

```text
ip route get 100.64.248.124 mark 0x80000
100.64.248.124 via 192.168.0.1 dev eno1 src 192.168.1.1 mark 0x80000

ip route get 100.66.83.109 mark 0x80000
100.66.83.109 via 192.168.0.1 dev eno1 src 192.168.1.1 mark 0x80000

ip route get 100.64.248.124 mark 0x0
100.64.248.124 dev tailscale0 table 52 src 100.100.1.1
```

Strict rpfilter therefore rejects tailnet packets before the normal input rules
for TCP/22 or ICMP matter. Opening SSH globally or trusting `tailscale0` in the
input chain is not the core fix if the packet is already dropped in
`prerouting`.

No declarative `eth0`, `eno1`, or `192.168.1.1` host route was found in `pvl-x2`
history. The physical-interface choice is an emergent live routing result:
NetworkManager/DHCP gives `pvl-x2` a main-table default via `eno1`, and
Tailscale's marked policy rules consult the main/default tables before the
tailnet table. The Incus project-scoping work did not explicitly force tailnet
traffic onto `eno1`, but it did expand `pvl-x2`'s bridge/route topology around
the same period, which made this older strict-rpfilter/Tailscale assumption
visible during new remote-delegation workflows.

The `eth0` references in the Incus configuration are guest/profile device names,
not the pvl-x2 underlay NIC. For example, each Incus default profile declares a
device named `eth0` with a `network` property such as `incusbr0`, `ipvlbr0`, or
`iabirdbr0`. The project route reconciler reads that profile `network` property
and emits host routes against the bridge name. The generated pvl-x2 route JSON
for the legacy subnet is:

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

The route helper applies that as `ip -4 route replace ... dev incusbr0`, not
`dev eth0`.

## Correct Fix

Use the first-class Tailscale/NixOS routing option on hosts that need reliable
tailnet client traffic:

```nix
services.tailscale.useRoutingFeatures = "client";
```

The upstream NixOS module maps `"client"` and `"both"` to:

```nix
networking.firewall.checkReversePath = "loose";
```

Loose reverse-path filtering keeps the anti-spoofing check but removes the
strict incoming-interface match from the generated nftables `fib` rule. Use
`"both"` only for hosts that also need Tailscale subnet-router or exit-node
server behavior because it enables IP forwarding.

Apply this at the Tailscale enablement boundary, not only on `pvl-x2`. In this
repo that means the common physical-host network profile and the Incus guest
helper. The failure is structural to "Tailscale client plus strict NixOS
rpfilter"; `client` is still narrower than enabling forwarding and is the
least-surprising default for tailnet participants.

## Investigation Notes

- Do not infer effective pvl-x2 firewall ports from `hosts/pvl-x2/firewall.nix`
  alone. The evaluated config includes additional ports from OpenSSH and service
  modules.
- The Incus managed-fabric nftables table only matches managed bridge
  interfaces. It is not the direct rule dropping `tailscale0` traffic.
- `tailscale ping` without `--icmp` is a disco-layer diagnostic. Normal `ping`,
  `nc`, or `tailscale ping --icmp` are better tests for OS packet-path
  reachability.
- Cloudflare Access route `x.p7log.com` can be used as a read-only escape hatch
  for pvl-x2 diagnostics when direct tailnet SSH is broken.

## 2026-06-12 Follow-up: Policy-Like Asymmetric Block

After `useRoutingFeatures = "client"` was deployed, the original strict rpfilter
failure was no longer the active cause on `pvl-x2` or `pvl-l5`:

- both hosts reported Tailscale `1.98.5`;
- both hosts had `net.ipv4.conf.tailscale0.rp_filter = 2`;
- `pvl-x2` generated nftables rules had loose rpfilter and allowed TCP ports
  including `22`, `443`, `8443`, and service ports;
- `pvl-x2` could initiate ordinary Tailscale ICMP, TCP/22, and PeerAPI traffic
  to `pvl-l5`.

The live failure was asymmetric and source-specific:

- `pvl-l5 -> pvl-x2` timed out for ICMP, TCP/22, TCP/8443, service ports, and
  the pvl-x2 PeerAPI at `100.100.1.1:47929`;
- tagged VM nodes such as `abird-ci`, `gap3-gondor`, and `gap3-rivendell` could
  reach pvl-x2 TCP/22 and PeerAPI over Tailscale;
- `pvl-l5` could reach tagged VM nodes over Tailscale using ordinary ICMP,
  TCP/22, and PeerAPI.

That evidence points away from NixOS firewall/rpfilter and toward Tailscale's
tailnet policy/filtering for the user-owned `pvl-l5 -> pvl-x2` direction. If
this recurs, first check the Tailscale ACL or node policy for user-device to
user-device traffic before changing host firewall rules.

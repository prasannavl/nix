# Placement-aware service client access

For a restricted internal listener, declare authorized callers once on the
service registry's named port:

```nix
smtpInternal = {
  port = 10026;
  allowedServices = ["outline" "zulip" "opencloud" "grafana"];
};
```

Applications consume
`registry.clientEndpointForService {client; service; portName;}`, which returns
`host` and `port`. The listener owner consumes
`registry.allowedClientIpv4CidrsFor service portName` to render its IPv4
firewall rule. Loopback allowances remain an explicit listener-owner choice.
These helpers are opt-in; unrestricted ports retain their existing APIs. Unknown
declared services and unauthorized client requests fail evaluation. An absent
client policy authorizes no callers.

Resolve both sides with `endpointForService`, including service-role remapping,
explicit endpoint-group placement and phase projection. Services share a host
only when their endpoint project, host and address all match. Do not maintain
separate local and remote caller lists, or compare role names alone.

For callers with a declared `podmanSubnet`, a local connection uses
`host.containers.internal` and the firewall allows that container subnet. A
remote connection uses the target service address and allows only the caller
endpoint's IPv4 `/32`. Callers without a declared subnet use direct service
addresses and endpoint `/32` sources, preserving Grafana's existing route.
Duplicate sources are removed. IPv6 sources are rejected by the IPv4 helper.

This contract models the repo's existing bridge and guest-egress paths.
`podmanSubnet` must describe an actual local bridge source; it is not merely
informational metadata for host-network or custom-egress clients. Remote
container traffic must leave as its registered guest address. Additional network
modes require explicit registry modeling and regression coverage before using
these helpers. A guest `/32` grants access to traffic from that guest; it does
not authenticate an individual application.

When a caller or listener moves, validate both rendered application settings and
listener firewall sources. Cover the original placement, destination placement
and migration projection. After deployment, verify TCP and protocol handshake
from actual containers; pure evaluation cannot prove the deployed NAT path.
Sending acceptance mail requires an explicitly authorized recipient.

Regression checks are `lib-flake-service-client-endpoints` and
`lib-flake-phase-projection`.

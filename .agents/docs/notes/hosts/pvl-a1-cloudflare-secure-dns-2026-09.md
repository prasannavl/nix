# Pvl Cloudflare Secure DNS

## Decision

Pvl core hosts use systemd-resolved's global resolver settings for strict
Cloudflare DNS over TLS:

- both Cloudflare IPv4 and IPv6 resolver addresses include the `one.one.one.one`
  TLS authentication name;
- `DNSOverTLS=true` requires encrypted transport instead of allowing a plaintext
  downgrade;
- `DNSSEC=true` validates signed answers locally;
- `Domains=~.` makes Cloudflare the routing choice for ordinary DNS instead of
  DHCP-provided link resolvers; and
- an empty `FallbackDNS` prevents fallback to compiled-in resolvers.

The policy lives in `lib/network.nix`, which currently reaches `pvl-a1`,
`pvl-l5`, `pvl-x2`, and the generic VM profile. Incus LXC and Incus VM profiles
own separate networking modules and do not inherit it. Each resolved setting is
a `lib.mkDefault`, so a host can override the policy without `lib.mkForce` when
its network requirements differ.

## Tailscale compatibility

Tailscale DNS remains enabled. The pinned Tailscale 1.102.3 resolved backend
programs `tailscale0` over D-Bus with link-scoped DNS servers and routing
domains, then explicitly sets `SetLinkDNSOverTLS(..., "no")` and
`SetLinkDNSSEC(..., "no")`. The link's longer MagicDNS and reverse-DNS routing
domains take precedence over the global `~.` route, while the link exemption
keeps the local `100.100.100.100` resolver from being forced to use TLS.

The live `pvl-a1`, `pvl-l5`, and `pvl-x2` pre-change states confirmed MagicDNS,
`tailscale0` marked `-DefaultRoute`, and route-only tailnet domains. The tailnet
currently has no global resolver override, so it does not install a competing
`~.` route. All three hosts reached both Cloudflare IPv4 and IPv6 endpoints on
TCP/853; the connections completed TLS handshakes and passed `one.one.one.one`
certificate hostname verification. Their ordinary network links had no search
domains that would route queries to a non-DoT LAN resolver.

Strict DoT is intentionally fail-closed. A roaming network or captive portal
that blocks TCP/853 can make public DNS unavailable until the network permits
DoT. This is distinct from Tailscale compatibility and is the reason the shared
settings remain overridable defaults.

MagicDNS availability and application availability are separate checks. In the
pre-change live state, `pvl-a1` resolved the single-label `pvl-x2` name to
`pvl-x2.tailcaaad.ts.net` at `100.100.1.1`, Tailscale ping succeeded, and TCP/22
was reachable. `https://pvl-x2` itself failed because TCP/443 on `pvl-x2` was
closed or filtered; that existing service/port state is unrelated to this
resolver policy.

## Validation

Before deployment, evaluate these boundaries:

```sh
for host in pvl-a1 pvl-l5 pvl-x2; do
  nix eval --json \
    ".#nixosConfigurations.$host.config.services.resolved.settings.Resolve"
  nix eval --raw \
    ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath"
done
```

After deployment, verify both resolver paths:

```sh
resolvectl status
resolvectl query cloudflare.com
resolvectl query pvl-a1.tailcaaad.ts.net
tailscale dns status
```

The expected global status is authenticated Cloudflare servers with
`+DNSOverTLS`; the expected `tailscale0` status remains `-DNSOverTLS` with its
MagicDNS routing domains.

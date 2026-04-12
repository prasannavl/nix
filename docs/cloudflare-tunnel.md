# Cloudflare Tunnel

Cloudflare Tunnel model for repo-managed hosts.

## Source Of Truth

- Host tunnel wiring: `hosts/<host>/cloudflare.nix`
- Shared helper: `lib/services/tunnels/cloudflare.nix`
- Tunnel objects and routes: `tf/cloudflare-platform/`
- Tunnel DNS hostnames: `tf/cloudflare-dns/dns.auto.tfvars`
- Host listener hostnames: `cfTunnelNames` on
  `services.podmanCompose.<stack>.instances.<name>.exposedPorts.<port>`

## Outcome: Expose A Host Through An Existing Tunnel

Use the existing host tunnel when these are all true:

- same host
- same trust boundary
- same operator ownership
- same listener or same nginx layer

Typical pattern:

- one tunnel object per host
- many public hostnames on that tunnel
- nginx or the local listener routes by `Host` and path

For `gap3-rivendell`, both `gap3.ai` and `api.gap3.ai` use the same tunnel.

## Outcome: Add A New Public Hostname To A Tunnel-Backed Host

Required changes:

1. Add the hostname to the listener exposed through the tunnel.
2. Add the public DNS record pointing at the tunnel domain.

For nginx-backed listeners, step 1 usually means adding the hostname to
`cfTunnelNames`.

Example:

```nix
exposedPorts.http = {
  port = 8000;
  openFirewall = true;
  cfTunnelNames = [
    "gap3.ai"
    "api.gap3.ai"
  ];
};
```

DNS example:

```hcl
{
  key     = "cname-api"
  content = "9b4d8502-ff4d-4ebe-8c33-ad55e7737c57.cfargotunnel.com"
  name    = "api"
  proxied = true
  ttl     = 1
  type    = "CNAME"
}
```

Use a durable `key` that does not depend on list order. Inserting another DNS
record nearby must not change the Terraform identity of existing records.

Result:

- Cloudflare resolves `api.gap3.ai` to the tunnel
- cloudflared receives the request for that hostname
- the host listener selected by `cfTunnelNames` receives the request

## Outcome: Add A New Tunnel

Create a separate tunnel only when you need a real boundary:

- different host or failure domain
- different credentials or rotation boundary
- different ownership or operational lifecycle
- different security policy
- different transport requirements

Repository surfaces:

- tunnel object: `tf/cloudflare-platform/tunnels.auto.tfvars`
- host runtime config: `hosts/<host>/cloudflare.nix`
- credentials secret: `data/secrets/cloudflare/tunnels/*.json.age`

Do not create a second tunnel just to add another hostname on the same host.

## Runtime Model

Cloudflare has two separate concerns:

- DNS maps a public hostname to `<tunnel-uuid>.cfargotunnel.com`
- host runtime config maps that hostname to a local origin

Both must exist.

Missing DNS:

- hostname does not resolve to the intended tunnel

Missing host ingress entry:

- Cloudflare can resolve the tunnel hostname but the tunnel does not serve that
  hostname

## Repo Model

### Terraform Platform

`tf/cloudflare-platform/tunnels.auto.tfvars` owns tunnel objects:

```hcl
tunnels = {
  "gap3-rivendell" = {
    name       = "gap3-rivendell"
    config_src = "local"
  }
}
```

This does not define per-hostname ingress for local-config tunnels.

### Host Runtime

`hosts/<host>/cloudflare.nix` wires the host-managed tunnel:

- `tunnelId`
- credential secret
- derived `ingress`
- edge IP policy

Common pattern:

```nix
tunnelsLib.mkHostManagedTunnel {
  inherit config tunnelId;
  credentialsStoreName = "gap3-rivendell.json.age";
  ingress = config.services.podmanCompose.gap3.cloudflareTunnelIngress;
  edgeIPVersion = "auto";
}
```

### Derived Ingress

`config.services.podmanCompose.<stack>.cloudflareTunnelIngress` is derived from
`cfTunnelNames` and maps each public hostname to a local origin URL.

For nginx listeners this is usually:

- `hostname -> http://127.0.0.1:<listener-port>`

### DNS

`tf/cloudflare-dns/dns.auto.tfvars` publishes the public hostname to the tunnel
domain.

Example:

- `gap3.ai -> 9b4d...cfargotunnel.com`
- `api.gap3.ai -> 9b4d...cfargotunnel.com`
- `z.gap3.ai -> 55eb...cfargotunnel.com`

Different hostnames may point to different tunnels. Hostnames on the same host
often point to the same tunnel.

## Verification

Check all three layers:

1. DNS record exists for the public hostname.
2. Host tunnel ingress contains the hostname.
3. Local origin is healthy behind the host listener.

Useful checks:

- `nix eval --json .#nixosConfigurations.<host>.config.services.podmanCompose.<stack>.cloudflareTunnelIngress`
- inspect `tf/cloudflare-dns/dns.auto.tfvars`
- inspect `hosts/<host>/cloudflare.nix`
- verify local origin port before debugging Cloudflare

## Related Docs

- [`docs/nginx.md`](./nginx.md)
- [`docs/podman-compose.md`](./podman-compose.md)
- [`tf/cloudflare-platform/README.md`](../tf/cloudflare-platform/README.md)
- [`tf/cloudflare-dns/README.md`](../tf/cloudflare-dns/README.md)

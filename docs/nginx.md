# Nginx

Shared ingress model for static content, reverse proxies, subpath mounts, rate
limits, forwarded-client headers, and Cloudflare Tunnel host routing.

## Source Of Truth

- Shared renderer: `lib/services/nginx/default.nix`
- NixOS option surface: `lib/services/nginx/module.nix`
- Container runtime config: `lib/services/nginx/compose/nginx.conf`
- Security headers include:
  `lib/services/nginx/compose/conf.d/lib/http-security.conf`
- Host usage example: `hosts/gap3-rivendell/services/nginx.nix`
- Derived compose metadata source: `lib/podman-compose/default.nix`

## Outcomes

Use this model for these outcomes:

- Serve a root static website on a hostname
- Mount a static website under a subpath
- Proxy a backend service on its own hostname
- Mount a backend service under a subpath
- Proxy to an external domain or Cloud Run origin
- Add a fixed upstream path prefix with `prependPath`
- Apply nginx-managed rate limits
- Preserve forwarded client identity to upstream services
- Publish hostnames through the derived Cloudflare Tunnel ingress

## Core Model

There are three ingress declaration surfaces:

- `exposedPorts.<name>` on a
  `services.podmanCompose.<stack>.instances.<service>` entry
- `proxyVhosts` passed to `nginxLib.renderServers`
- `staticSites` passed to `nginxLib.renderServers`

Most callers do not construct `proxyVhosts` manually. They come from
`services.podmanCompose.<stack>.nginxProxyVhosts`, which is derived from
`exposedPorts`.

Most path-mounted dynamic routes do not construct route attrsets manually. They
come from `services.podmanCompose.<stack>.nginxRoutes`, which is derived from
`exposedPorts.<name>.nginxRoutes`.

Manual route attrsets are valid when the origin is external and not represented
as a local compose service.

## Outcome: Add A Root Static Site

Declare a static site and pass it to `renderServers`.

```nix
let
  staticSites.docs = nginxLib.mkStaticSite {
    serverNames = ["docs.example.com"];
    rootPath = mySitePath;
    singlePageApp = true;
  };
in {
  files."conf.d/srv-http-default.conf" = nginxLib.renderServers {
    staticSites = staticSites;
  };
}
```

Result:

- nginx serves `docs.example.com`
- no backend container is needed
- root requests resolve from `rootPath`

## Outcome: Add A Static Site Under A Subpath

Use `routes` on the static site.

```nix
staticSites.hello = nginxLib.mkStaticSite {
  rootPath = helloSite;
  singlePageApp = true;
  routes = [
    {
      serverName = "gap3.ai";
      path = "/hello";
    }
  ];
};
```

Result:

- `GET /hello` redirects to `/hello/`
- `GET /hello/...` serves from the static tree
- root-relative HTML assets are rewritten onto `/hello/`

## Outcome: Add A Backend On Its Own Hostname

Declare `nginxHostNames` on an exposed port.

```nix
instances.api = rec {
  exposedPorts.http = {
    port = 12000;
    openFirewall = true;
    nginxHostNames = ["api.example.com"];
    cfTunnelNames = ["api.example.com"];
    rateLimit = null;
  };
};
```

Result:

- firewall opens the declared port when `openFirewall = true`
- nginx creates a root proxy vhost for `api.example.com`
- Cloudflare Tunnel ingress is derived from `cfTunnelNames`

## Outcome: Mount A Backend Under A Subpath

Declare `nginxRoutes` on an exposed port.

```nix
instances.app = rec {
  exposedPorts.http = {
    port = 13000;
    openFirewall = true;
    nginxRoutes = [
      {
        serverName = "example.com";
        path = "/app";
        stripPath = true;
      }
    ];
  };
};
```

Result when `stripPath = true`:

- `GET /app` redirects to `/app/`
- `GET /app/` proxies as `/`
- `GET /app/x` proxies as `/x`

Result when `stripPath = false`:

- `GET /app` proxies as `/app`
- `GET /app/x` proxies as `/app/x`

For HTML responses, root-relative asset references are rewritten onto the public
mount prefix.

## Outcome: Forward To Another Domain

Use a manual route attrset when the origin is not a local compose service.

```nix
{
  service = null;
  mode = "upstream";
  serverName = "api.example.com";
  path = "/whatsapp";
  port = 443;
  upstreams = ["origin.example.com:443"];
  upstreamProtocol = "https";
  upstreamHost = "origin.example.com";
  stripPath = true;
  rateLimit = nginxLib.rateLimitProfiles.default;
}
```

Use this for:

- Cloud Run
- third-party HTTP services
- external APIs behind a fixed hostname

Rules:

- `upstreams` must be plain `host[:port]`
- `upstreamHost` must be a plain hostname
- `upstreamHost` must not include `http://`, `https://`, or `/`
- `upstreamProtocol` selects `http` or `https` for `proxy_pass`

Behavior:

- nginx dials `upstreams`
- nginx sends `Host: <upstreamHost>` when `upstreamHost != null`
- nginx sets TLS SNI with `proxy_ssl_name <upstreamHost>` when using HTTPS

## Outcome: Add A Fixed Upstream Path Prefix

Use `prependPath`.

```nix
{
  serverName = "api.example.com";
  path = "/whatsapp";
  upstreams = ["origin.example.com:443"];
  upstreamProtocol = "https";
  upstreamHost = "origin.example.com";
  prependPath = "/api/v1";
  stripPath = true;
}
```

Result:

- public `GET /whatsapp/x`
- upstream request path `/api/v1/x`

With `stripPath = false`:

- public `GET /whatsapp/x`
- upstream request path `/api/v1/whatsapp/x`

Additional behavior when `prependPath != null`:

- absolute upstream redirects rooted at `prependPath` are rewritten back onto
  the public path mount
- common root-relative HTML asset links are rewritten back onto the public path
  mount
- nginx sends `X-Forwarded-Prefix`

## Outcome: Apply Rate Limits

Rate limits can be applied at:

- the shared nginx listener passed to `renderServers`
- an exposed port
- a manual route or proxy vhost

The shared default is `nginxLib.rateLimitProfiles.default`.

Default profile:

- `10 r/s`
- `300 r/m`
- no quarter-hour limit
- no hourly limit

Resolved limits are keyed by client IP after nginx real-IP normalization.

## Outcome: Preserve Real Client Identity Upstream

Shared proxy header behavior lives in `lib/services/nginx/compose/nginx.conf`.

Configured behavior:

- `real_ip_header X-Forwarded-For`
- `real_ip_recursive on`
- trust only localhost and private-network proxy hops declared by
  `set_real_ip_from`
- `X-Real-IP $remote_addr`
- `CF-Connecting-IP $remote_addr`
- `X-Forwarded-For $proxy_add_x_forwarded_for`
- `X-Forwarded-Proto $scheme`
- `X-Forwarded-Host $host`
- `X-Forwarded-Port $server_port`

Operational assumption:

- nginx sits behind a trusted local proxy such as `cloudflared`
- the trusted proxy already supplies `X-Forwarded-For`

Under that model, `$remote_addr` resolves to the actual client IP before nginx
forwards the request upstream.

## Outcome: Publish Hostnames Through Cloudflare Tunnel

`services.podmanCompose.<stack>.cloudflareTunnelIngress` is derived from
`cfTunnelNames` on exposed ports.

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

Result:

- derived tunnel ingress maps both hostnames to the local listener

Manual routes do not create tunnel hostnames by themselves. The hostname still
must be present on a listener exposed through `cfTunnelNames`.

This document covers only the nginx-side tunnel touch points. For tunnel
objects, host runtime wiring, DNS, and when to reuse vs split tunnels, see
[`docs/cloudflare-tunnel.md`](./cloudflare-tunnel.md).

## Option Reference

### `exposedPorts.<name>`

Common fields used by the nginx and tunnel model:

- `port`: local host port
- `openFirewall`: whether host firewall opens the port
- `nginxHostNames`: root proxy hostnames for this backend
- `nginxRoutes`: subpath mounts for this backend
- `cfTunnelNames`: hostnames published through derived Cloudflare Tunnel ingress
- `cfTunnelPort`: optional port override for tunnel ingress
- `rateLimit`: ingress rate-limit policy

### `exposedPorts.<name>.nginxRoutes[]`

- `serverName`: public hostname
- `path`: public mount prefix, must be non-root
- `stripPath`: whether nginx removes the public prefix before proxying

Derived defaults for these routes:

- `upstreams = [ "<nginxDefaultHost>:<port>" ]`
- `upstreamProtocol = "http"`
- `upstreamHost = null`
- `prependPath = null`

### `proxyVhost`

Shared attrset type in `lib/services/nginx/default.nix`:

- `service`: optional compose dependency service name
- `serverNames`: root hostnames served by the vhost
- `port`: backend port
- `upstreams`: backend addresses as `host[:port]`
- `upstreamProtocol`: `http` or `https`
- `upstreamHost`: optional host for `Host` and TLS SNI
- `prependPath`: optional fixed upstream path prefix
- `rateLimit`: resolved rate-limit profile or `null`

### `route`

Shared attrset type in `lib/services/nginx/default.nix`:

- `service`: optional compose dependency service name
- `mode`: `"static"` or `"upstream"`
- `serverName`: public hostname
- `path`: public mount prefix
- `port`: backend port or `null`
- `upstreams`: backend addresses as `host[:port]`
- `upstreamProtocol`: `http` or `https`
- `upstreamHost`: optional host for `Host` and TLS SNI
- `prependPath`: optional fixed upstream path prefix
- `stripPath`: whether nginx removes the public mount prefix
- `siteMountPath`: static route source directory
- `siteIndex`: static route index file
- `siteSinglePageApp`: static route SPA fallback mode
- `rateLimit`: resolved rate-limit profile or `null`

### `nginxLib.mkStaticSite`

- `serverNames ? []`: root hostnames for this static site
- `rootPath`: directory tree to mount
- `mountPath ? null`: explicit mount path inside the nginx container
- `index ? "index.html"`: index file
- `singlePageApp ? false`: SPA fallback mode
- `routes ? []`: static subpath mounts

Rules:

- `rootPath` must be a real Nix path or derivation-backed path
- do not pass a stringified store path for directory mounts

### `nginxLib.renderServers`

Arguments:

- `rateLimit ? null`: shared default rate-limit profile for static roots and
  static routes
- `nginxRoutes ? {}`: dynamic and static route attrsets keyed by route name
- `proxyVhosts ? {}`: root proxy vhosts keyed by vhost name
- `staticSites ? {}`: static-site declarations keyed by site name

Outputs:

- upstream blocks
- rate-limit zones
- merged `server {}` blocks for all root hosts and mounted routes

### `rateLimit`

Resolved rate-limit profile shape:

- `enable`
- `requestsPerSecond`
- `requestsPerSecondBurst`
- `requestsPerMinute`
- `requestsPerMinuteBurst`
- `requestsPerQuarterHour`
- `requestsPerQuarterHourBurst`
- `requestsPerHour`
- `requestsPerHourBurst`
- `statusCode`
- `bypass.cidrs`
- `bypass.lan`
- `bypass.cloudflareTunnel`

Semantics:

- `enable = false` disables rate limiting
- if all request-rate windows are `null`, no nginx rate-limit directives are
  rendered
- bypass rules apply before nginx limit keys are computed

## Render And Merge Behavior

`nginxLib.renderServers` merges these into one generated config:

- root static sites
- root proxy vhosts
- static routes
- dynamic routes

Constraints:

- a hostname cannot have both a root static site and a root proxy vhost
- path routes on a hostname are merged into the same server block
- duplicate root hostnames are rejected

## Host Pattern

Typical host wiring:

```nix
services.podmanCompose.gap3.instances.nginx = rec {
  exposedPorts.http = {
    port = 8000;
    openFirewall = true;
    cfTunnelNames = [
      "gap3.ai"
      "api.gap3.ai"
    ];
  };

  dependsOn = nginxLib.dependencyServices (proxyVhosts // nginxRoutesAll);

  files."conf.d/srv-http-default.conf" = nginxLib.renderServers {
    rateLimit = exposedPorts.http.rateLimit or null;
    nginxRoutes = nginxRoutesAll;
    proxyVhosts = proxyVhosts;
    staticSites = staticSites;
  };
};
```

## Related Docs

- [`docs/cloudflare-tunnel.md`](./cloudflare-tunnel.md)
- [`docs/podman-compose.md`](./podman-compose.md)
- [`docs/services.md`](./services.md)

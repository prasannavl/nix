# Nginx

Shared ingress model for static content, reverse proxies, subpath mounts, rate
limits, forwarded-client headers, and Cloudflare Tunnel host routing.

## Source Of Truth

- Shared renderer: `lib/services/nginx/default.nix`
- NixOS option surface: `lib/services/nginx/module.nix`
- Container runtime config: `lib/services/nginx/compose/nginx.conf`
- Security headers include:
  `lib/services/nginx/compose/conf.d/lib/http-security.conf` (composed from
  per-header sub-files: `http-security-xcto.conf`,
  `http-security-referrer.conf`, `http-security-permissions.conf`,
  `http-security-csp.conf`)
- Host usage example: `hosts/pvl-x2/services/nginx.nix`
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
      serverName = "example.com";
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
  # upstreamTlsName defaults to "auto", deriving SNI from upstreamHost.
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
- `upstreamHost` must be a plain host or `host:port` value
- `upstreamHost` must not include `http://`, `https://`, or `/`
- `upstreamTlsName` must be `"auto"`, `null`, or a plain hostname without a port
- `upstreamProtocol` selects `http` or `https` for `proxy_pass`

Behavior:

- nginx dials `upstreams`
- nginx sends `Host: <upstreamHost>` when `upstreamHost != null`
- with HTTPS and `upstreamTlsName = "auto"`, nginx derives SNI from
  `upstreamHost` when it is host-only
- with HTTPS and `upstreamTlsName = "<host>"`, nginx sends that explicit SNI
- with HTTPS and `upstreamTlsName = null`, nginx emits no SNI directives
- when `resolver` is set on a manual route, nginx resolves the single upstream
  at request time and skips the static upstream block

## Outcome: Add A Fixed Upstream Path Prefix

Use `prependPath`.

```nix
{
  serverName = "api.example.com";
  path = "/whatsapp";
  upstreams = ["origin.example.com:443"];
  upstreamProtocol = "https";
  upstreamHost = "origin.example.com";
  upstreamTlsName = "origin.example.com";
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

## Outcome: Handle Large Headers Or Uploads

Set proxy buffer or request body size limits on root vhosts or routes.

```nix
{
  serverNames = ["app.example.com"];
  upstreams = ["127.0.0.1:3000"];
  proxyBufferSize = "16k";
  clientMaxBodySize = "128m";
}
```

The same knobs are available on `exposedPorts.<name>` and
`exposedPorts.<name>.nginxRoutes[]`; route values override exposed-port values.

## Outcome: Add Auth Request

Use `authRequest` on a manual root proxy vhost or route when nginx should guard
the upstream through an `oauth2-proxy` forward-auth endpoint.

```nix
{
  serverNames = ["app.example.com"];
  upstreams = ["127.0.0.1:3000"];
  authRequest = {
    upstream = "oauth2-proxy:4180";
    resolver = "127.0.0.11 valid=30s";
    externalScheme = "https";
    prefix = "/oauth2";
  };
}
```

The renderer emits the public auth callback/sign-in locations and an internal
`/auth` subrequest location once per server block.

## Outcome: Rewrite Upstream Redirects And Cookies

`proxyCookiePath` replaces the default cookie path rewrite target.
`proxyRedirects` adds explicit redirect rewrites before the default
path-preserving rewrite.

```nix
{
  path = "/app";
  upstreams = ["127.0.0.1:3000"];
  proxyCookiePath = "/app/";
  proxyRedirects = [
    {
      from = "http://127.0.0.1:3000/";
      to = "https://app.example.com/app/";
    }
  ];
}
```

## Outcome: Let The Upstream Own A Security Header

Some backends (Grafana, etc.) emit their own `Content-Security-Policy`,
`Referrer-Policy`, or `Permissions-Policy`. The shared nginx listener declares
defaults for these at server scope, so without an opt-out the client receives
two copies and the browser intersects them, which typically breaks upstream
nonce-based or feature-gated policies.

Per-header opt-out flags, each default `false`:

- `useUpstreamCsp` — suppress global `Content-Security-Policy`
- `useUpstreamReferrer` — suppress global `Referrer-Policy`
- `useUpstreamPermissionsPolicy` — suppress global `Permissions-Policy`

Available on:

- `exposedPorts.<name>.*` for the derived root proxy vhost
- `exposedPorts.<name>.nginxRoutes[].*` for a subpath route
- the same fields directly on a manual `proxyVhost` or `route` attrset

Behavior at a location with any opt-out set:

- the server-scope `http-security.conf` include is shadowed at that location
  (nginx `add_header` inheritance is replace-not-merge)
- the renderer re-includes only the sub-files that are not opted out:
  `http-security-xcto.conf` is always re-included; the corresponding
  `-referrer.conf`, `-permissions.conf`, `-csp.conf` is omitted for each header
  the upstream owns
- the upstream's response header passes through unfiltered

Other locations on the same server block keep the global headers.

The upstream remains responsible for emitting a secure header. For Grafana's
CSP, set `GF_SECURITY_CONTENT_SECURITY_POLICY=true` so it emits its default
nonce-based template (`$NONCE` placeholder in `script-src`). For Open WebUI, set
`useUpstreamCsp = true` and provide a compatible `CONTENT_SECURITY_POLICY`
environment variable from the app layer, because the frontend uses inline
bootstrap code and blob workers.

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
    "example.com"
    "api.example.com"
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
- `upstreamProtocol`: `http` or `https` for nginx proxying
- `upstreamHost`: optional `Host` header override for nginx proxying
- `upstreamTlsName`: TLS SNI name for HTTPS nginx upstreams; `"auto"` derives
  from `upstreamHost`, `null` disables SNI
- `rootRedirect`: optional exact-root redirect on a derived root vhost
- `proxyBufferSize`: optional `proxy_buffer_size` for large upstream response
  headers
- `clientMaxBodySize`: optional `client_max_body_size` for uploads
- `proxyCookiePath`: optional replacement path for `proxy_cookie_path`
- `proxyRedirects`: additional `proxy_redirect` rewrites
- `cfTunnelNames`: hostnames published through derived Cloudflare Tunnel ingress
- `cfTunnelPort`: optional port override for tunnel ingress
- `rateLimit`: ingress rate-limit policy
- `useUpstreamCsp`: suppress global CSP on the derived root vhost so the
  upstream's CSP passes through
- `useUpstreamReferrer`: suppress global `Referrer-Policy` on the derived root
  vhost
- `useUpstreamPermissionsPolicy`: suppress global `Permissions-Policy` on the
  derived root vhost

### `exposedPorts.<name>.nginxRoutes[]`

- `serverName`: public hostname
- `path`: public mount prefix, must be non-root
- `stripPath`: whether nginx removes the public prefix before proxying
- `useUpstreamCsp`: suppress global CSP on this route so the upstream's CSP
  passes through
- `useUpstreamReferrer`: suppress global `Referrer-Policy` on this route
- `useUpstreamPermissionsPolicy`: suppress global `Permissions-Policy` on this
  route
- `proxyBufferSize`: optional `proxy_buffer_size` for large upstream response
  headers
- `clientMaxBodySize`: optional `client_max_body_size` for uploads
- `proxyCookiePath`: optional replacement path for `proxy_cookie_path`
- `proxyRedirects`: additional `proxy_redirect` rewrites

Derived defaults for these routes:

- `upstreams = [ "<nginxDefaultHost>:<port>" ]`
- `upstreamProtocol` inherits from the exposed port
- `upstreamHost` inherits from the exposed port
- `upstreamTlsName` inherits from the exposed port
- `prependPath = null`
- `proxyBufferSize` and `clientMaxBodySize` inherit from the exposed port

### `proxyVhost`

Shared attrset type in `lib/services/nginx/default.nix`:

- `service`: optional compose dependency service name
- `serverNames`: root hostnames served by the vhost
- `port`: backend port
- `upstreams`: backend addresses as `host[:port]`
- `upstreamProtocol`: `http` or `https`
- `upstreamHost`: optional host for the `Host` header
- `upstreamTlsName`: TLS SNI name for HTTPS upstreams; `"auto"` derives from
  `upstreamHost`, `null` disables SNI
- `prependPath`: optional fixed upstream path prefix
- `rootRedirect`: optional exact-root redirect before the normal root proxy
- `rateLimit`: resolved rate-limit profile or `null`
- `proxyBufferSize`: optional `proxy_buffer_size` for large upstream response
  headers
- `clientMaxBodySize`: optional `client_max_body_size` for uploads
- `proxyCookiePath`: optional replacement path for `proxy_cookie_path`
- `proxyRedirects`: additional `proxy_redirect` rewrites
- `authRequest`: optional forward-auth integration
- `useUpstreamCsp`: suppress global CSP so upstream CSP passes through
- `useUpstreamReferrer`: suppress global `Referrer-Policy`
- `useUpstreamPermissionsPolicy`: suppress global `Permissions-Policy`

### `route`

Shared attrset type in `lib/services/nginx/default.nix`:

- `service`: optional compose dependency service name
- `mode`: `"static"` or `"upstream"`
- `serverName`: public hostname
- `path`: public mount prefix
- `port`: backend port or `null`
- `upstreams`: backend addresses as `host[:port]`
- `resolver`: optional nginx resolver for dynamic single-upstream routing
- `upstreamProtocol`: `http` or `https`
- `upstreamHost`: optional host for the `Host` header
- `upstreamTlsName`: TLS SNI name for HTTPS upstream routes; `"auto"` derives
  from `upstreamHost`, `null` disables SNI
- `prependPath`: optional fixed upstream path prefix
- `stripPath`: whether nginx removes the public mount prefix
- `siteMountPath`: static route source directory
- `siteIndex`: static route index file
- `siteSinglePageApp`: static route SPA fallback mode
- `rateLimit`: resolved rate-limit profile or `null`
- `proxyBufferSize`: optional `proxy_buffer_size` for large upstream response
  headers
- `clientMaxBodySize`: optional `client_max_body_size` for uploads
- `proxyCookiePath`: optional replacement path for `proxy_cookie_path`
- `proxyRedirects`: additional `proxy_redirect` rewrites
- `authRequest`: optional forward-auth integration
- `useUpstreamCsp`: suppress global CSP so upstream CSP passes through
- `useUpstreamReferrer`: suppress global `Referrer-Policy`
- `useUpstreamPermissionsPolicy`: suppress global `Permissions-Policy`

### `authRequest`

- `provider ? "oauth2-proxy"`: currently the only supported provider
- `upstream ? "oauth2-proxy:4180"`: plain auth provider `host:port`
- `resolver ? null`: optional nginx resolver for dynamic provider lookup
- `externalScheme ? null`: externally visible scheme for redirects and forwarded
  headers; defaults to `$scheme`
- `prefix ? "/oauth2"`: public auth callback and sign-in prefix
- `passHeaders ? true`: forward identity headers to the protected upstream
- `clientMaxBodySize ? null`: optional body-size override for the internal auth
  request location

## Outcome: Redirect Exact Root Before Proxying

Use `rootRedirect` on a root proxy vhost when `/` should bounce to a deeper app
path before the normal catch-all proxy location runs.

```nix
instances.vmui = {
  exposedPorts.http = {
    port = 8428;
    nginxHostNames = ["vmui.example.com"];
    rootRedirect = {
      path = "/vmui/";
      status = 307;
    };
  };
};
```

Result:

- `GET /` returns the configured redirect
- `GET /x` still follows the normal proxy location

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
- `includeHttpPreamble ? true`: include upstream blocks and rate-limit zones
  before server blocks
- `listenDirectives ? [ "listen 80;" ]`: listen directives for generated server
  blocks
- `serverExtraDirectives ? ""`: extra raw directives inserted after
  `server_name`

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
services.podmanCompose.pvl.instances.nginx = rec {
  exposedPorts.http = {
    port = 8000;
    openFirewall = true;
    cfTunnelNames = [
      "example.com"
      "api.example.com"
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

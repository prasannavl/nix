# Nginx Vhosts, Static Sites, Exposed Ports, And Tunnels

This document explains the current repo pattern for exposing web traffic through
the shared nginx service, including:

- static sites
- proxied API or app services
- `exposedPorts`
- rate limits
- Cloudflare Tunnel wiring

The goal is to make the mental model obvious before looking at the Nix code.

## Mental Model

There are two different kinds of nginx-served traffic in this repo:

1. Static sites that nginx serves directly from files.
2. Dynamic services that nginx proxies to another local port.

Both use nginx vhosts, but they are configured differently:

- static sites are declared with `nginxLib.mkStaticSite`
- proxied services are derived automatically from
  `exposedPorts.<name>.nginxHostNames`

The nginx service itself owns the public listener and ingress policy:

- which host port nginx listens on
- whether the firewall is opened
- which hostnames should route through Cloudflare Tunnel
- the shared rate limit for static sites on that listener

Dynamic proxied services keep their own per-service policy through their own
`exposedPorts`.

## `exposedPorts`

`exposedPorts` is the common ingress metadata surface for a service. It is used
for more than container port publishing.

An `exposedPorts.<name>` entry can drive:

- compose port mappings
- firewall openings
- nginx reverse-proxy vhost generation
- Cloudflare Tunnel ingress generation
- request rate limiting

Typical shape:

```nix
exposedPorts.http = {
  port = 12000;
  openFirewall = true;
  nginxHostNames = ["app.example.com"];
  cfTunnelNames = ["app.example.com"];
  rateLimit = null;
};
```

Important fields:

- `port`: the host port
- `openFirewall`: whether to open that port on the host firewall
- `nginxHostNames`: hostnames nginx should proxy to this port
- `cfTunnelNames`: hostnames Cloudflare Tunnel should route to this port
- `rateLimit`: ingress rate-limit policy for that port

## Static Sites

Static sites are nginx vhosts only. They do not define their own listener ports.
The nginx service owns that.

Current pattern:

```nix
let
  staticSites = {
    gap3-ai-web = nginxLib.mkStaticSite {
      serverNames = ["gap3.ai"];
      rootPath = builtins.path {
        path = (pkgs.callPackage ../../pkgs/gap3-ai-web/default.nix {}) + "/share/gap3-ai-web";
        name = "gap3-ai-web-site";
      };
      singlePageApp = true;
    };
  };
in {
  services.podmanCompose.gap3.instances.nginx = rec {
    exposedPorts.http = {
      port = 10800;
      openFirewall = true;
      cfTunnelNames = ["gap3.ai"];
      rateLimit = null;
    };

    files."conf.d/srv-http-default.conf" =
      nginxLib.renderStaticServers {rateLimit = exposedPorts.http.rateLimit or null;} staticSites;
  };
}
```

Key points:

- `mkStaticSite` describes hostnames and content roots
- nginx `exposedPorts.http` describes the listener and public ingress policy
- static sites on the same nginx listener share the same rate limit
- `singlePageApp = true` enables `try_files ... /index.html`

For static content, always pass a real Nix path for the mounted site tree. Do
not pass a stringified store path like `"${drv}/share/site"`, because that gets
staged as file content instead of a directory tree.

## Proxied API And App Services

Dynamic services do not need manual nginx server blocks when they fit the
standard proxy pattern. Instead, they expose a port and set
`nginxHostNames = [...]`.

Example:

```nix
instances.open-webui = rec {
  exposedPorts.http = {
    port = 12000;
    openFirewall = true;
    nginxHostNames = ["chat.example.com"];
    cfTunnelNames = ["chat.example.com"];
rateLimit = {
  requestsPerSecond = 5;
  requestsPerSecondBurst = 10;
};
  };

  source = ''
    services:
      open-webui:
        image: ghcr.io/open-webui/open-webui:main
        restart: unless-stopped
        ports:
          - "0.0.0.0:${toString exposedPorts.http.port}:8080"
  '';
};
```

From that one `exposedPorts.http` entry, the shared modules derive:

- firewall openings
- nginx reverse-proxy vhost
- Cloudflare Tunnel ingress
- per-service rate-limit policy

This is the right pattern for APIs and web apps that should keep different rate
limits from the static sites served by nginx itself.

## Rate Limits

Rate limiting is nginx-managed and keyed by client IP after nginx real-IP
normalization.

The shared built-in default lives in:

- `lib/services/nginx/default.nix`
- path: `nginxLib.rateLimitProfiles.default`

The shared default applies both:

- a short-window `10 r/s` limit
- a longer-window `300 r/m` limit
- no quarter-hour or hourly limit by default

Current default:

```nix
{
  enable = true;
  requestsPerSecond = 10;
  requestsPerSecondBurst = 30;
  requestsPerMinute = 300;
  requestsPerMinuteBurst = 900;
  requestsPerQuarterHour = null;
  requestsPerQuarterHourBurst = null;
  requestsPerHour = null;
  requestsPerHourBurst = null;
  statusCode = 429;
  bypass = {
    cidrs = [];
    lan = false;
    cloudflareTunnel = false;
  };
}
```

Meaning of `rateLimit` values:

- `rateLimit = null`
  - use nginx's shared default profile
- `rateLimit = { enable = false; }`
  - disable rate limiting entirely
- `rateLimit = { ... }`
  - define an explicit custom rate-limit policy from scratch

Each limiter window can also be disabled independently:

- `requestsPerSecond = null`
  - do not apply the per-second limiter
- `requestsPerMinute = null`
  - do not apply the per-minute limiter
- `requestsPerQuarterHour = null`
  - do not apply the quarter-hour limiter
- `requestsPerHour = null`
  - do not apply the hourly limiter

If both are `null`, no request-rate limiter is applied.

Example custom API limit:

```nix
rateLimit = {
  requestsPerSecond = null;
  requestsPerSecondBurst = null;
  requestsPerMinute = 60;
  requestsPerMinuteBurst = 12;
  requestsPerQuarterHour = 600;
  requestsPerQuarterHourBurst = 60;
  requestsPerHour = null;
  requestsPerHourBurst = null;
  bypass.cloudflareTunnel = true;
};
```

### Bypass Controls

`bypass` controls which requests skip the rate limit:

- `cidrs`
  - explicit allowlisted ranges
- `lan = true`
  - bypass loopback and private LAN ranges
- `cloudflareTunnel = true`
  - bypass requests that arrived through a trusted local `cloudflared` hop with
    `CF-Connecting-IP`

`cloudflareTunnel = true` is broad. It does not mean "trust public Cloudflare
edge IPs." It means "requests forwarded to nginx by the local tunnel connector
are exempt."

## Cloudflare Tunnel

Cloudflare Tunnel ingress is derived from `exposedPorts`.

If a service sets:

```nix
cfTunnelNames = ["gap3.ai"];
```

then the shared podman-compose module derives tunnel ingress that points to:

```text
http://127.0.0.1:<port>
```

For example, nginx on port `10800` becomes:

```text
gap3.ai -> http://127.0.0.1:10800
```

This means:

- the service declares the hostname once on its `exposedPorts`
- nginx or the backend service owns the origin port
- the tunnel helper can derive the target automatically

Host-managed Cloudflare Tunnel configuration itself lives separately in the
shared tunnel helper:

- `lib/services/tunnels/cloudflare.nix`

That helper handles:

- credentials staging
- `services.cloudflared.tunnels.<id>`
- edge IP policy such as `edgeIPVersion = "auto"`

## How The Pieces Fit Together

### Static site flow

1. Build a site package or otherwise produce a real directory path.
2. Declare a static site with `mkStaticSite`.
3. Put listener policy on the nginx service's `exposedPorts.http`.
4. Render the static nginx config with `renderStaticServers`.
5. Let `cfTunnelNames` on nginx drive tunnel ingress if needed.

### Dynamic API/app flow

1. Expose the backend's host port with `exposedPorts.<name>.port`.
2. Add `nginxHostNames` for reverse proxying.
3. Add `cfTunnelNames` if the service should be reached through Tunnel.
4. Set `rateLimit` on that same exposed port if it needs custom behavior.
5. Let the shared module derive the nginx vhost and tunnel ingress.

## Current Repo Example

On `gap3-rivendell` today:

- nginx listens on `10800`
- `gap3.ai` is a static site served directly by nginx
- the static site uses `singlePageApp = true`
- Cloudflare Tunnel routes `gap3.ai` to nginx on `127.0.0.1:10800`
- static nginx traffic uses the shared default rate limit unless explicitly
  overridden
- proxied services can still define their own `rateLimit` values per port

See:

- `hosts/gap3-rivendell/services.nix`
- `lib/services/nginx/default.nix`
- `lib/podman-compose/default.nix`
- `lib/services/tunnels/cloudflare.nix`

## When To Use Which Pattern

Use a static site when:

- nginx should serve files directly
- the app is a built frontend, docs site, or SPA bundle

Use a proxied service when:

- another process or container owns the actual app server
- nginx should terminate ingress and proxy to that backend
- the service needs its own rate limit or its own vhost hostnames

Keep the listener on nginx when:

- multiple static sites share one ingress policy
- nginx is the public entrypoint

Keep `rateLimit` on each backend service when:

- APIs or dynamic apps need different limits
- machine-to-machine traffic differs from browser traffic

## Related Docs

- `docs/podman-compose.md`
- `docs/services.md`
- `docs/ai/design-patterns/tunnels-and-static-origins.md`
- `docs/ai/notes/services/nginx-proxy-rate-limits-2026-04.md`

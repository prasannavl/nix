# Nginx Path Routing

## Scope

- Shared nginx reverse-proxy support for mounting a backend under a path prefix
  on an existing nginx-served hostname.

## Decisions

- `services.podmanCompose.<stack>.instances.<name>.exposedPorts.<port>.nginxRoutes`
  is the application-facing metadata surface for dynamic nginx path routes.
- `nginxLib.mkStaticSite.routes` is the application-facing metadata surface for
  static nginx path routes.
- Each route declares:
  - `serverName`
  - `path`
- Dynamic `nginxRoutes` additionally declare `stripPath`.
- `path` must be a non-root prefix that starts with `/`; whole-host routing
  remains on `nginxHostNames`.
- The shared podman-compose module derives
  `services.podmanCompose.<stack>.nginxRoutes` from those per-port
  route declarations.
- Shared nginx static-site rendering derives route blocks from
  `mkStaticSite.routes` automatically and also accepts dynamic `nginxRoutes`.
- `stripPath = true` means requests mounted at `/hello` are proxied to the
  backend without the `/hello` prefix, so `GET /hello/world` becomes
  `GET /world` upstream.
- Static routes are always treated as root-assuming applications mounted behind
  a prefix, so nginx rewrites common root-relative HTML asset references like
  `href="/..."` and `src="/..."`.
- When `stripPath = true`, nginx redirects the bare prefix path to a trailing
  slash first, preserving the query string, so `/hello?a=1` becomes
  `/hello/?a=1` before proxying.
- Dynamic routes inherit the enclosing exposed port's `rateLimit`; static routes
  inherit the shared nginx static-site rate limit.

## Rationale

- Hostname-only reverse proxying was insufficient for mounting multiple apps
  under one public hostname.
- Path routes belong inside the existing hostname's `server` block, so the
  feature belongs in the shared renderer rather than as another standalone
  vhost generator.
- Static and dynamic path routes should share one nginx routing model so root
  path assumptions are handled consistently.

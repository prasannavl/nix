# Nginx Proxy Rate Limits

## Scope

- Shared nginx reverse-proxy defaults derived from
  `services.podmanCompose.<stack>.instances.<name>.exposedPorts`.

## Decisions

- Derived proxy vhosts now carry a `rateLimit` policy in the shared nginx
  metadata model.
- `exposedPorts.<name>.rateLimit` is the application-facing override point for
  derived nginx proxy vhosts.
- The shared default is per-client request limiting keyed by
  `$binary_remote_addr`.
- Default `rate = "10r/s"`.
- Default `burst = 20`.
- Default `nodelay = true`.
- Default `statusCode = 429`.
- Applications can tune the limit by overriding `rate`, `burst`, `key`,
  `zoneSize`, `statusCode`, or `dryRun`.
- Applications can disable the shared proxy rate limit entirely with
  `rateLimit = null`.

## Rationale

- The default should exist in one place so new proxied apps get a baseline
  guardrail without each host re-implementing nginx snippets.
- The policy still belongs to the application surface because traffic profiles
  vary widely between human-facing apps, APIs, and machine-to-machine paths.

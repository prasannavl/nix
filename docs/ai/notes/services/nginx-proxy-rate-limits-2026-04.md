# Nginx Proxy Rate Limits

## Scope

- Shared nginx reverse-proxy defaults derived from
  `services.podmanCompose.<stack>.instances.<name>.exposedPorts`.

## Decisions

- Derived proxy vhosts now carry a `rateLimit` policy in the shared nginx
  metadata model.
- `exposedPorts.<name>.rateLimit` is the application-facing override point for
  derived nginx proxy vhosts.
- The shared default lives in `lib/services/nginx/default.nix` as
  `rateLimitProfiles.default`, not in per-stack config.
- `rateLimit = null` means "use the shared nginx default profile".
- `rateLimit = { enable = false; }` disables rate limiting entirely.
- `rateLimit = { ... }` creates an explicit policy from scratch using the
  option-type defaults for unspecified fields.
- `requestsPerSecond = null` disables the short-window limiter.
- `requestsPerMinute = null` disables the longer-window limiter.
- `requestsPerQuarterHour = null` disables the quarter-hour limiter.
- `requestsPerHour = null` disables the hourly limiter.
- If both limiter windows are `null`, no request-rate limiter is applied.
- The shared default is per-client request limiting keyed by
  `$binary_remote_addr`.
- Default short-window `rate = "10r/s"`.
- Default short-window `burst = 30`.
- Default longer-window `rate = "300r/m"`.
- Default longer-window `burst = 900`.
- Quarter-hour and hourly windows are supported but unset by default.
- Default `nodelay = true`.
- Default `statusCode = 429`.
- Applications can tune the limit by overriding `requestsPerSecond`,
  `requestsPerSecondBurst`, `requestsPerMinute`, `requestsPerMinuteBurst`,
  `requestsPerQuarterHour`, `requestsPerQuarterHourBurst`, `requestsPerHour`,
  `requestsPerHourBurst`, `statusCode`, or bypass settings.

## Rationale

- The default should exist in one place so new proxied apps get a baseline
  guardrail without each host re-implementing nginx snippets.
- The policy still belongs to the application surface because traffic profiles
  vary widely between human-facing apps, APIs, and machine-to-machine paths.

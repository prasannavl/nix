# Gap3 Unit 6 Nginx Composer Port 2026-05

## Scope

Unit 6 ports the reusable nginx ingress composer and generic proxy/trusted-CA
features from the post-`8314da5b` `gap3` range.

This unit intentionally stays at the library/type/rendering layer. It does not
add Abird or Gap3 route data, host service modules, DNS values, OAuth
application wiring, concrete stack registry values, or encrypted secrets.

## Ported

- `lib/services/nginx/default.nix` now has the `web` rate-limit profile,
  redirect vhost type/rendering, `proxyBuffering`, and `mkProxyTimeout` /
  `mkProxyTimeouts` helpers.
- `lib/services/nginx/ingress-composer.nix` adds generic helpers for composing
  root proxies, routes, HTTPS upstreams, edge-protected proxies/routes,
  oauth2-proxy routes, and service attr merges from a service registry.
- `lib/flake/units.nix` adds `sizeToBytes` and `sizesToBytes` helpers used by
  stack libraries and ingress limit metadata.
- `lib/flake/stack/lib.nix` exposes `stack.lib.mkNginxLib`, stack unit helpers,
  CA bundle metadata, and resolved nginx limit helpers while preserving local
  stack CA hash behavior.
- `lib/podman-compose/default.nix` adds `trustedCa`, `trustedCaCertificates`,
  stack `trustedCaDefaults`, trusted-CA file-secret conversion, generated mount
  and runtime trust environment overrides, source-hash restart detection, and
  `proxyBuffering` exposed-port metadata.
- `docs/nginx.md` and `docs/ai/design-patterns/podman-compose-instance.md`
  document the reusable redirect, buffering, and trusted-CA surfaces.

## Skipped

- `aaa5c704` is treated as usage examples only. Its Abird and Gap3 route
  applications are not imported.
- Host/app-specific portions of `83506a27` are skipped, including Abird proxy
  route files, service module rewrites, OAuth/auth-request policy, DNS names,
  and concrete stack registry values.
- Existing local root-redirect, upstream TLS-name, proxy timeout, and Cloudflare
  tunnel derivation behavior was kept instead of replaying older equivalent
  upstream hunks.

## Validation Contract

Validate this unit with:

- `alejandra -c` on touched Nix files
- `deno fmt --check` on touched Markdown files
- focused Nix evals for redirect/composer rendering and trusted-CA module
  normalization
- `nix flake check --no-build`, plus `nix run .#lint -- --diff --base master`
  when feasible

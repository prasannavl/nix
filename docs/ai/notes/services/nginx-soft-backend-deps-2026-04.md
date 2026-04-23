# Nginx soft backend dependencies (2026-04)

- Scope: `hosts/gap3-rivendell/services/nginx.nix`, `docs/ai/README.md`

## Decision

Host-managed nginx ingress should use soft startup dependencies on downstream
backend services, not hard requirements.

## Why

- Nginx can start and serve static content even when some proxy backends are
  down.
- For unhealthy upstreams, the correct failure mode is route-level `502`/`504`,
  not taking down the ingress service itself.
- Hard `Requires` edges make unrelated downstream regressions fan out into a
  full ingress outage.
- On `gap3-rivendell`, nginx depended on Grafana, which depended on the removed
  `prometheus` service; that transitive hard edge prevented nginx from starting
  at all after deploy.

## Rule

- For nginx proxy backends discovered from route/vhost metadata, generate soft
  `Wants`-style dependencies rather than hard `Requires`.
- Keep ingress startup independent from downstream application readiness unless
  nginx itself cannot render valid config without that dependency.

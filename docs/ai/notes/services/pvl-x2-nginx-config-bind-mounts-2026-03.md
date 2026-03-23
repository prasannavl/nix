# pvl-x2 Nginx Config Bind Mounts (2026-03)

## Scope

Capture the March 2026 migration of the `pvl-x2` nginx compose instance from a
port-only container definition to repo-managed nginx config files bind-mounted
through the existing `services.podmanCompose.pvl.instances.nginx` flow.

## Decisions

- Source config tree came from `/home/pvl/tmp/nginx`.
- Repo-managed nginx config now lives under `lib/services/nginx/compose/`, while
  host modules only provide host-specific proxy declarations and generated vhost
  output.
- `hosts/pvl-x2/services.nix` materializes `nginx.conf` and `conf.d/**` through
  the compose module `files` mechanism.
- `hosts/pvl-x2/compose/nginx/compose.yaml` bind-mounts those staged files into
  `/etc/nginx/nginx.conf` and `/etc/nginx/conf.d`.
- Proxy virtual hosts are now generated in Nix from
  `services.podmanCompose.pvl.instances.<service>.exposedPorts.<name>`, where
  `nginxHostNames` and `cfTunnelNames` opt a port into nginx and Cloudflare
  wiring, and `cfTunnelPort` can redirect tunnel traffic through nginx's host
  port instead of the backend port.
- `hosts/pvl-x2/cloudflare.nix` now derives tunnel ingress from
  `services.podmanCompose.pvl.cloudflareTunnelIngress`, while nginx consumes
  `services.podmanCompose.pvl.nginxProxyVhosts`.
- The shared nginx rendering helpers live in `lib/services/nginx/default.nix`.
- Static nginx compose assets were extracted into
  `lib/services/nginx/compose/**` and exposed through
  `lib/services/nginx/default.nix`.
- Cloudflare tunnel ingress rendering was extracted into
  `lib/services/tunnels/default.nix`.

## Notes

- `templates/` and `www/` existed in `/home/pvl/tmp/nginx` but were empty during
  migration, so only config payloads were brought into the repo-managed compose
  tree.
- The initial generated proxy set covers `docmost.example.com`,
  `memos.example.com`, and `vaultwarden.example.com` and makes nginx depend on
  those backend compose services.
- The backend service ports for `docmost`, `memos`, and `vaultwarden` are also
  the source of truth for the generated nginx vhosts, while Cloudflare can
  explicitly target nginx's shared host port through `cfTunnelPort`, reducing
  drift between compose, nginx, and Cloudflare tunnel ingress.

# Automatic Ingress Metadata

- Add optional `nginxHostNames` and `cfTunnelNames` metadata to
  `services.podmanCompose.<stack>.instances.<service>.exposedPorts.<name>`.
- Allow `cfTunnelPort` to override the tunnel target port so a hostname can be
  declared on one exposed service port but forwarded through another local port
  such as a shared nginx reverse proxy.
- Derive nginx reverse-proxy vhosts and Cloudflare Tunnel ingress separately
  from the resolved podman instance graph instead of maintaining a separate
  manual `x.nginxProxyVhosts` map.
- Expose the derived nginx vhost map as
  `services.podmanCompose.<stack>.nginxProxyVhosts` so host modules can consume
  one read-only stack-local source of truth.
- Expose the derived Cloudflare ingress as
  `services.podmanCompose.<stack>.cloudflareTunnelIngress`.
- Keep the metadata opt-in per exposed port so firewall exposure and ingress
  exposure remain separate decisions.

## Nginx proxy abstraction (2026-03-24)

- `proxyVhostType` is a single unified submodule with `service` (nullable),
  `serverNames`, `port`, and `upstreams` (list of `host:port` strings).
- `upstreams` supports multiple backends per vhost; nginx renders an `upstream`
  block per vhost and `proxy_pass`es to it.
- The default upstream host differs by context:
  - Podman stacks: configurable via `nginxDefaultHost` on the stack, defaults to
    `host.containers.internal`.
  - Non-podman services: `localhost` (the default for `proxyVhostsFromInstances`
    and direct `proxyVhostType` usage).
- `mkProxyVhost` accepts `{ defaultHost }` and explicitly sets `upstreams` in
  the produced attrset to avoid submodule default evaluation-order issues.
- `service` is `nullOr str` (default `null`) so non-podman vhosts don't need
  to declare a compose dependency. `dependencyServices` filters out nulls.
- Non-podman vhosts can be defined directly as `proxyVhostType` attrsets and
  merged into the vhost map passed to `renderProxyServers`.

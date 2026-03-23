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

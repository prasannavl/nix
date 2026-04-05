# Tunnels And Static Origins

## Scope

- Apply these rules when a host exposes services through Cloudflare Tunnel and
  serves static assets through `services.podmanCompose`.
- Treat tunnel transport choice and origin materialization as first-class design
  concerns, not ad hoc per-host tweaks.

## Tunnel Edge Policy

- Configure Cloudflare Tunnel edge IP behavior at the tunnel level through the
  native NixOS option `services.cloudflared.tunnels.<id>.edgeIPVersion`.
- Prefer the shared helper in `lib/services/tunnels/cloudflare.nix` for
  host-managed tunnels so credential staging, default-service wiring, and edge
  transport policy stay aligned across hosts.
- The common-case helper contract should only need `credentialsStoreName`,
  `tunnelId`, and `ingress`.
- By convention, the helper derives the agenix secret path as
  `data/secrets/cloudflare/tunnels/<credentialsStoreName>` and the age secret
  name as `cloudflare-tunnel-<basename>-credentials`, where `<basename>` drops
  `.json.age` or `.age`.
- Keep `ageSecretName` and `credentialsSecretPath` as optional escape hatches
  for non-standard layouts only.
- Do not use the invalid top-level shape `services.cloudflared.edgeIpVersion`.
  It is not a supported NixOS option.
- Do not assume IPv4 reachability to Cloudflare edge `:7844` just because the
  host has ordinary outbound IPv4 on `:443`.
- When a guest or network path has asymmetric connectivity, prefer
  `edgeIPVersion = "auto"` so the managed service can use IPv6 when that is the
  healthy path.
- Use `edgeIPVersion = "6"` only when the host is intentionally IPv6-only or
  `auto` is known to be incorrect for that environment.

## Tunnel Health Checks

- Before switching public DNS to a tunnel-backed hostname, verify both:
  - the hostname points at the intended tunnel target
  - the target tunnel has live connections from the serving host
- A `1033` error means Cloudflare can resolve the tunnel hostname but no healthy
  tunnel connector is serving it.
- Tunnel rollout order should be:
  - make the host-side tunnel healthy
  - verify origin health behind the tunnel
  - switch public DNS

## Static Origin Materialization

- Prefer the shared helpers in `lib/services/nginx/default.nix` for static
  domain wiring so server blocks, staged site trees, container mounts, listener
  policy, and tunnel/firewall exposure stay in one declarative model.
- Static sites are nginx vhosts only. Keep the public listener, firewall
  exposure, tunnel hostnames, and shared static-site rate limit on the nginx
  service's `exposedPorts`.
- Use one nginx listener to serve multiple static sites when they share the same
  ingress policy. This keeps static-site declarations focused on hostnames and
  content roots instead of duplicating listener metadata.
- Keep per-service rate limits on dynamic/API services through their own
  `exposedPorts`, so derived proxy vhosts can still vary limits independently.
- `services.podmanCompose.<stack>.instances.<name>.files` distinguishes between
  text/attrs values and real Nix paths.
- Directory expansion only happens when the value is an actual Nix path
  (`builtins.isPath value == true`).
- Do not pass a stringified store path such as `"${drv}/share/site"`. That is
  treated as file content and will stage a file containing the path text, not
  the directory tree.
- For directory-backed mounts, pass a real path object. Preferred patterns are:
  - `./relative/path`
  - `someDrv`
  - `builtins.path { path = someDrv + "/share/site"; name = "..."; }`
- When the runtime target should be a directory mount inside a container, the
  source value in `files` must also be directory-shaped at evaluation time.

## Origin Verification

- Validate origin health separately from tunnel health.
- For nginx-served static apps, verify the local origin port before debugging
  the tunnel path.
- A local `500` with nginx redirect-cycle errors usually indicates a broken
  `root` or `try_files` target, often from a bad file-vs-directory mount.

## Preferred Direction

- Keep tunnel ingress derived from the host's declared service metadata so the
  origin map and tunnel map stay in one model.
- Keep Cloudflare transport policy explicit in host config, because network path
  asymmetry is a host property, not a DNS property.
- Keep Podman compose file materialization type-safe: use real paths for mounted
  trees, text for generated files, and attrs only for YAML-rendered content.

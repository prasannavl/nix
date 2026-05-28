# Podman Compose Instance Attribute Ordering

When defining a `services.podmanCompose.<stack>.instances.<name>` attribute set,
follow this canonical ordering. Not every instance uses every attribute —
include only what applies, but keep the relative order stable.

## Attribute Order

1. **Config flags** — `reload`, `imageTag`, `bootTag`, `reloadTag`,
   `recreateTag`, `recreateOnSwitch`
2. **exposedPorts**
3. **network identity** — `subnet` when a stable compose default-network subnet
   is declared
4. **source** (inline compose YAML or a lib-provided value)
5. **entryFile** (when a custom compose entry is needed)
6. **dependsOn**
7. **env** / **envSecrets**
8. **dirs**
9. **fileSecrets** / **trustedCa** / **files**
10. **serviceOverrides.preStart**

## Why

- Ports define the service's external contract and are referenced by `source`,
  so they come first.
- `subnet` defines the instance's network identity and is checked for repo-wide
  clashes, so keep it near the top before compose source details.
- `source` is the compose definition — the core of the instance — and sits right
  after ports.
- `entryFile` directly qualifies `source`, so it stays adjacent.
- Dependencies and environment are wiring concerns that support the compose
  definition.
- `dirs`, `fileSecrets`, and `files` all stage the runtime tree. Keep `dirs`
  first so bind-mounted directory ownership is declared before staged files that
  may live under those directories.
- `trustedCa` injects stack-level public CA material into selected compose
  services. It stages, mounts, and optionally exposes the CA through common
  runtime trust environment variables. Use `trustedCaCertificates` only for
  low-level multi-CA or non-profile cases. Keep app-native CA flags in `source`
  when an app requires a specific option such as `custom_ca_path`,
  `OC_LDAP_CACERT`, or `ssl.ca_file_path`.
- When a container needs read-only repo-built package content, prefer a direct
  `/nix/store` bind mount by interpolating the derivation in `source`, such as
  `"${pkg}:/container/path:ro"`. This keeps the package in the system closure
  and avoids copying it into the compose working directory, where rootless
  Podman user mappings and staged directory modes can make the path unreadable
  to a non-root container user. Use `files` / `dirs` staging only when the
  runtime path must be mutable, secret-bearing, mode-adjusted, or otherwise
  deliberately materialized under the compose workdir.
- `preStart` runs before the container starts and often depends on staged path
  layout, so it comes last.

## Network And Timeout Debugging

- Keep the default Podman/Compose network mode unless the user explicitly asks
  to change it. Do not switch a service to `network_mode: host` as a debugging
  shortcut for rootless port, DNS, or readiness failures. First fix the actual
  published-port, rootless namespace, service readiness, or provisioning error
  inside the existing network model.
- Do not raise `timeoutStableSeconds`, `TimeoutStartSec`, or related settling
  windows just because a deploy is slow or a health check is stuck. A long
  start-post or health-settling delay usually means the service is failing
  elsewhere: an unreachable local port, a crashed container, a stale pod, a bad
  secret, or an auto-apply/provisioning error.
- Increase startup timeouts only when a normal healthy startup path is measured
  to require it, and document the reason next to the override.

## Example

```nix
services.podmanCompose.pvl.instances.example = rec {
  recreateTag = "1";

  exposedPorts.http = {
    port = 8080;
  };

  subnet = "10.89.10.0/24";

  source = ''
    services:
      example:
        image: docker.io/example:latest
        ports:
          - "127.0.0.1:${toString exposedPorts.http.port}:8080"
        volumes:
          - /var/lib/example:/data
  '';
  dependsOn = ["postgres"];
  files."example/config.yml" = ''
    key: value
  '';
  serviceOverrides.preStart = ''
    install -d -m 0750 /var/lib/example
  '';
};
```

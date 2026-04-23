# Podman Compose Instance Attribute Ordering

When defining a `services.podmanCompose.<stack>.instances.<name>` attribute set,
follow this canonical ordering. Not every instance uses every attribute —
include only what applies, but keep the relative order stable.

## Attribute Order

1. **Config flags** — `imageTag`, `bootTag`, `recreateOnSwitch`
2. **exposedPorts**
3. **source** (inline compose YAML or a lib-provided value)
4. **entryFile** (when a custom compose entry is needed)
5. **dependsOn**
6. **env** / **envSecrets**
7. **dirs**
8. **fileSecrets** / **files**
9. **serviceOverrides.preStart**

## Why

- Ports define the service's external contract and are referenced by `source`,
  so they come first.
- `source` is the compose definition — the core of the instance — and sits right
  after ports.
- `entryFile` directly qualifies `source`, so it stays adjacent.
- Dependencies and environment are wiring concerns that support the compose
  definition.
- `dirs`, `fileSecrets`, and `files` all stage the runtime tree. Keep `dirs`
  first so bind-mounted directory ownership is declared before staged files that
  may live under those directories.
- `preStart` runs before the container starts and often depends on staged path
  layout, so it comes last.

## Example

```nix
services.podmanCompose.gap3.instances.example = rec {
  recreateOnSwitch = true;

  exposedPorts.http = {
    port = 8080;
  };

  source = ''
    services:
      example:
        image: docker.io/example:latest
        ports:
          - "127.0.0.1:${toString exposedPorts.http.port}:8080"
        volumes:
          - /var/lib/gap3/example:/data
  '';
  dependsOn = ["postgres"];
  files."example/config.yml" = ''
    key: value
  '';
  serviceOverrides.preStart = ''
    install -d -m 0750 /var/lib/gap3/example
  '';
};
```

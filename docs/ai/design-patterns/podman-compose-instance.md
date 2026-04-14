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
7. **fileSecrets** / **files**
8. **serviceOverrides.preStart**

## Why

- Ports define the service's external contract and are referenced by `source`,
  so they come first.
- `source` is the compose definition — the core of the instance — and sits right
  after ports.
- `entryFile` directly qualifies `source`, so it stays adjacent.
- Dependencies, environment, and file mounts are wiring concerns that support
  the compose definition.
- `preStart` runs before the container starts and often depends on file/secret
  paths, so it comes last.

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

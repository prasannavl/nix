# Podman Compose Instance Attribute Ordering

When defining a `services.podman-compose.<stack>.instances.<name>` attribute
set, follow this canonical ordering. Not every instance uses every attribute —
include only what applies, but keep the relative order stable.

## Attribute Order

1. **Config flags** — `state`, `reconcilePolicy`, `removalPolicy`, `reload`,
   `imageTag`, `bootTag`, `reloadTag`, `recreateTag`
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
- `trustedCa` injects stack-level CA material into selected compose services. By
  default it mounts the stack CA bundled with public roots, which is the right
  choice for runtime trust variables such as `SSL_CERT_FILE` or
  `REQUESTS_CA_BUNDLE`. Set `publicRoots = false` when an app needs only the
  stack CA as an explicit app-native CA file. `trustedCa` can be a list when a
  service needs both files. Keep app-native CA flags in `source` when an app
  requires a specific option such as `custom_ca_path`, `OC_LDAP_CACERT`, or
  `ssl.ca_file_path`.
- `preStart` runs before the container starts and often depends on staged path
  layout, so it comes last.

## Lifecycle Policy

- Use `state = "stopped"` when an instance should remain declared but should be
  stopped and skipped by automatic start/reconcile. The generated unit remains
  manually startable; runtime files are staged on start and cleaned after stop.
  Cleaning staged files on stopped-state drains is accepted design, because it
  prevents stale generated files from surviving generation changes. The next
  start restages the current generation. Do not confuse this with declaration
  removal; removal is governed by `removalPolicy`.
- Use stack-level `reconcilePolicy` for the normal drift-action mode and
  per-instance `reconcilePolicy` only for exceptions. `inherit` resolves to the
  stack default before metadata reaches the helper.
- The default `auto` policy reloads reload-safe changes, restarts restart-class
  changes, and force-recreates for recreate-class drift through the generated
  `recreateStamp`.
- Keep the action classes narrow. Reload-safe directory/external-file inputs
  stay only in `reloadTriggers`; ordinary staged runtime files are restart
  class; exact single-file bind-mounted staged entries, image refresh, compose
  shape, env-file shape, and file-secret mount shape are recreate class.
- `restart` restarts for reload/restart-class and recreate-class drift without
  force-recreating containers; `recreate` collapses restart-class and
  recreate-class drift into a force-recreate.
- Use `removalPolicy = "keep"` only for manual takeover when a declaration is
  removed. It maps to user-manager takeover behavior; it is not a steady-state
  reconcile opt-out. The normal stack default is `delete`; use `stop` or
  `delete-all` only for explicit removal semantics. Re-declaring a kept working
  directory requires matching `.podman-compose/state.json` identity state or a
  one-time `adopt = true`.
- Do not use `autoStart = false` to mean desired stopped state. Keep `autoStart`
  for lower-level cold-start behavior on otherwise running services.

## Port Bindings

In Compose `ports` entries, use the shortest host-port form unless the host bind
address is intentionally part of the behavior:

- default bind: `"${toString exposedPorts.http.port}:8080"`
- intentional loopback-only bind:
  `"127.0.0.1:${toString exposedPorts.http.port}:8080"`
- intentional specific-interface bind:
  `"<address>:${toString exposedPorts.http.port}:8080"`

Do not write an explicit `0.0.0.0` host bind just to express the default.
Including a bind address should signal a deliberate reachability constraint.

Keep the default Podman/Compose network mode unless the user explicitly asks to
change it. Do not switch a service to `network_mode: host` as a debugging
shortcut for rootless port, DNS, or readiness failures. First fix the actual
published-port, rootless namespace, service readiness, or provisioning error
inside the existing network model.

## Startup Timeouts

Do not raise `timeoutStableSeconds`, `TimeoutStartSec`, or related service
settling windows just because a deploy is slow or a health check is stuck. A
long start-post or health-settling delay usually means the service is failing
elsewhere: an unreachable local port, a crashed container, a stale pod, a bad
secret, or an auto-apply/provisioning error. First inspect the user unit,
container state, logs, and readiness endpoint. Only increase timeouts when a
normal, healthy startup path is measured to require it and the reason is
documented next to the override.

## Example

```nix
services.podman-compose.pvl.instances.example = rec {
  state = "running";
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
          - "${toString exposedPorts.http.port}:8080"
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

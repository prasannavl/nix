# Podman Compose Instance Attribute Ordering

When defining a `services.podman-compose.<stack>.instances.<name>` attribute
set, follow this canonical ordering. Not every instance uses every attribute —
include only what applies, but keep the relative order stable.

## Attribute Order

1. **Config flags** — `state`, `reconcilePolicy`, `removalPolicy`, `reload`,
   `imageTag`, `bootTag`, `reloadTag`, `recreateTag`, `localImages`
2. **exposedPorts**
3. **network identity** — `subnet` when a stable compose default-network subnet
   is declared
4. **source** (inline compose YAML or a lib-provided value)
5. **entryFile** (when a custom compose entry is needed)
6. **dependsOn**
7. **env** / **envSecrets**
8. **dirs**
9. **fileSecrets** / **trustedCa** / **files**
10. **preStart** / **postStart** / **preStop**
11. **serviceOverrides**

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
- `preStart`, `postStart`, and `preStop` are helper-owned lifecycle hooks.
  `preStart` runs after helper-managed dirs, files, env secrets, and file
  secrets are staged and before `podman compose up`; use it for first-run env
  generation, image loads, bootstrap commands, and other work that depends on
  the staged runtime tree. `postStart` runs after compose readiness succeeds and
  is the right place for app reconcile/apply helpers that must observe the live
  service. `preStop` runs before the helper applies the compose stop policy and
  accepts a leading `-` on a command to ignore failure. Keep raw
  `serviceOverrides` last for true systemd-level overrides such as timeouts.

## Lifecycle Policy

- Pin image references to exact upstream version tags whenever the registry
  publishes a usable release tag. Use a `tag@sha256:<digest>` pin only for
  channel-only images where no versioned tag exists, so deploys stay
  reproducible without hiding normal version updates behind digest churn.
- For repo-built local Docker image tar derivations, do not load the tar in
  `preStart`. In structured compose sources, set `image = package;` when the
  package exposes `passthru.imageRef`. In inline YAML sources, use
  `image: nix-store:${package}`. The module rewrites the compose image to a
  normal generated runtime tag with the Nix image-tar store hash, loads the tar,
  and tags it to that runtime ref before `podman compose up`. This avoids stale
  Podman tags when the package changes without requiring manual image-tag bumps.
  Mixed local/remote compose instances pull only their declared remote image
  refs, so a generated local runtime tag is never sent to a registry. Use
  `localImages` only as an escape hatch for sources the module cannot infer
  automatically. Inline YAML `nix-store:` refs must also retain the source Nix
  string context and keep the image tar reachable through the generated
  local-image closure root in the service unit; helper metadata alone is not a
  deployment closure root.
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
- Failed starts must leave the compose project retryable. The helper owns
  `podman compose up` supervision and derives its deadline from the effective
  systemd `TimeoutStartSec`, keeping a small cleanup reserve before systemd
  would kill the helper. It must write compatible helper state before staging
  runtime directories or starting Compose, because a first-start failure can
  otherwise leave helper-created data directories that later retries reject as
  unmanaged. If compose output shows a fatal start error, the helper should
  terminate compose early instead of waiting for the full timeout.
- Failed-start cleanup removes only compose project containers and networks,
  including expected compose container names left behind by partial Podman
  storage state. Do not remove volumes or managed data directories on
  failed-start cleanup; persistent data recovery is a separate operator
  decision. `ExecStopPost` may call the same cleanup after a systemd timeout or
  helper crash, but it is a backstop rather than the primary failure path.
- The helper owns systemd lifecycle for compose projects. Before `stop`/`down`,
  it disables Podman restart policies on known project containers so Compose
  entries such as `restart: unless-stopped` cannot recreate a container while
  systemd is trying to stop the unit. Do not invent compose service names for
  opaque YAML sources; keep `expectedComposeServices` empty unless the source is
  a structured attrset or the service names are otherwise known.
- Keep expected-service verification separate from default file-secret mount
  targeting. Opaque YAML sources should not produce expected-service assertions,
  but fileSecrets with no explicit `services` still default to the instance
  service name so legacy string-YAML services keep their generated
  `/run/secrets/*` mounts.

## Port Bindings

In Compose `ports` entries, use the shortest host-port form unless the host bind
address is intentionally part of the behavior:

- default bind: `"${toString exposedPorts.http.port}:8080"`
- intentional loopback-only bind:
  `"127.0.0.1:${toString exposedPorts.http.port}:8080"`
- intentional specific-interface bind:
  `"<address>:${toString exposedPorts.http.port}:8080"`

Do not write an explicit `0.0.0.0` host bind just to express the default.
Including a bind address should signal a deliberate reachability constraint. Do
not use `registry.ipForService` as a host bind address. It is the routed service
target address, which may intentionally point at a different endpoint group
during a migration. For host listens, bind to loopback, omit the host address
for the default all-interface bind, or use an explicitly local endpoint address
only when the service truly requires one.

Keep the default Podman/Compose network mode unless the user explicitly asks to
change it. Do not switch a service to `network_mode: host` as a debugging
shortcut for rootless port, DNS, or readiness failures. First fix the actual
published-port, rootless namespace, service readiness, or provisioning error
inside the existing network model.

## Startup Timeouts

Do not raise `timeoutReadySeconds`, `TimeoutStartSec`, or related service
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
  preStart = [
    ''
    install -d -m 0750 /var/lib/example
  ''
  ];
};
```

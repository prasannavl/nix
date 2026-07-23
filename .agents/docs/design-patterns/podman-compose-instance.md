# Podman Compose Instance Attribute Ordering

When defining a `services.podman-compose.<stack>.instances.<name>` attribute
set, follow this canonical ordering. Not every instance uses every attribute —
include only what applies, but keep the relative order stable.

An instance may be a function of the module-provided context. After invoking
that function, the module evaluates its result through the same service
submodule as an ordinary attribute-set instance. Nested defaults under options
such as `exposedPorts` and tunnels therefore apply identically in both forms.

## Attribute Order

1. **Config flags** — `state`, `autoStart`, `startPriority`, `reconcilePolicy`,
   `removalPolicy`, `reload`, `imageTag`, `bootTag`, `reloadTag`, `recreateTag`,
   `localImages`
2. **exposedPorts**
3. **network identity** — `subnet` when a stable compose default-network subnet
   is declared
4. **source** (inline compose YAML or a lib-provided value)
5. **entryFile** (when a custom compose entry is needed)
6. **dependsOn**
7. **env** / **envSecrets**
8. **dirs**
9. **fileSecrets** / **trustedCa** / **files**
10. **preStart** / **preStop**
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
- `preStart` and `preStop` are helper-owned lifecycle hooks. `preStart` runs
  after helper-managed dirs, files, env secrets, and file secrets are staged and
  before `podman compose up`; use it for first-run env generation, image loads,
  bootstrap commands, and other work that depends on the staged runtime tree.
  `preStop` runs before the helper applies the compose stop policy and accepts a
  leading `-` on a command to ignore failure. Keep raw `serviceOverrides` last
  for true systemd-level overrides such as timeouts or `ExecStartPost`.

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
  automatically.
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
- Use `startPriority` only to shape native start-lane ordering under
  `startConcurrency`; it is not a dependency. Lower values start earlier only
  among services whose semantic dependencies are already scheduled. The module
  emits `After=`-only scheduling edges from main services to prior lane members'
  ready targets, so the lane stays occupied through reconcile and verify without
  causing unrelated services to fail through artificial `Requires=` coupling.
  Keep stage units outside these lane edges so preparation remains parallel.
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
  storage state. Preserve named volumes and managed data directories; persistent
  data recovery is a separate operator decision. Image-declared anonymous
  volumes are container artifacts, not persistent project data: snapshot their
  names before any container teardown and remove exactly that snapshot
  afterward. `compose_down` owns this invariant so stop, failed-start, reload,
  and removal paths cannot bypass it. `ExecStopPost` may call the same cleanup
  after a systemd timeout or helper crash, but it is a backstop rather than the
  primary failure path. A completed main-path cleanup leaves a short-lived
  completion marker for `ExecStopPost` to consume, so a normal failed start does
  not tear down the project twice.
- The generated Compose runtime-policy override is the single restart-policy
  authority and forces every known service to `restart: no`. Do not add a
  post-create `podman update --restart=no` pass: the July corp incident proved
  that this redundant control-plane mutation can wedge after Compose has already
  succeeded while still holding the per-user transaction. Do not invent compose
  service names for opaque YAML sources; keep `expectedComposeServices` empty
  unless the source is structured or the names are otherwise known.
- Rootless Podman lifecycle mutation is a per-service-user critical section, not
  a per-compose-project detail. The helper may stage files, run service-local
  hooks, and pull images in parallel, but operations that mutate shared rootless
  Podman/Netavark/Aardvark state must hold the shared rootless mutation
  transaction: image-store load/pull, mutation-capable `preStart`, conflicting
  container cleanup, project removal, `podman compose up`, stop/down,
  failed-start cleanup, and Podman-owned network reload. If the helper cannot
  enter this transaction, it must fail or defer; it must not fall back to an
  unlocked path.
- `<user>-managed.target` is the single aggregate graph root. It wants every
  auto-start instance's ready target and owns explicit full-user drain/resume;
  it is not the ordinary service reconfiguration owner. Keep auto-start main
  units `PartOf=` the aggregate target, and keep each ready target
  `PartOf=<service>.service`, so restarting a service invalidates only its own
  readiness checkpoint. Do not also attach main services through `WantedBy=` or
  create a second aggregate ready target. Let NixOS restart only changed main
  units. The per-user Podman mutation transaction serializes their short runtime
  mutations while unrelated applications stay up. Do not put
  `X-StopOnReconfiguration` or generation-local restart triggers on the target:
  NixOS re-submits active targets after daemon reload to pull new dependencies,
  while those fields turn target definition churn into a full fleet drain.
- Do not add a target-wanted oneshot that stops or starts its own target. That
  creates a second lifecycle owner inside the target transaction and can
  deadlock or repeat a drain. The separate migration-manager gate owns explicit
  full-user drain/resume through the managed target. Register the target's
  auto-start main/reconcile/verify nodes, per-service ready target, and shared
  mutating preflight as gate-only units so direct NixOS starts still receive
  `ConditionPathExists`; set both stop-on-drain and start-on-resume false on
  those child registrations so they never become independent orchestration
  owners. Do not add a child-to-root ordering edge: target dependency semantics
  already order the aggregate root after its wanted readiness graph, so a
  reverse edge creates an ordering cycle. Every generated managed graph must
  pass `systemd-analyze --user verify` while building the host closure. Keep
  stage and image-pull preparation outside the execution gate.
- Main compose services are bounded `Type=oneshot` units with
  `RemainAfterExit=true` and `Restart=no`. The helper owns exactly one Compose
  provider invocation. Provider bind/Aardvark failure, raw status 125, timeout,
  missing inventory, and generic application failure roll back once and fail;
  none authorize Compose replay. A running service's confirmed lookup miss for a
  running declared peer may authorize one project-scoped Podman network reload.
  Self-alias, public ingress, missing peers, and indeterminate Podman
  observations never authorize mutation. The correction marker is durable for
  the start generation so the provider and verifier cannot each correct once.
- One-shot ownership deliberately separates startup readiness from steady-state
  liveness. A container that exits after its ready target passed leaves that
  leaf unhealthy; it must not make the main unit fail later or restart the
  aggregate root. Deploy health and external monitoring should report and repair
  only that leaf by stopping its main service and starting its ready target. If
  automatic self-healing is added, give it a dedicated leaf-scoped owner with
  bounded backoff and an explicit mutation transaction. Never restore a
  persistent observer as the main process, and never let a query timeout invoke
  project teardown. Penpot's post-ready exit during the July storage incident is
  the reference failure for this boundary.
- Override Compose-defined restart policies to `restart: no` in the generated
  runtime policy file passed to `compose up`, so newly created containers never
  enter an independently restarting state. This declarative provider input is
  authoritative; do not follow it with a second Podman update pass. Derive
  service names centrally from structured or inline Compose sources; inline
  parsing must preserve documents whose top-level keys have common indentation.
- Keep long compose readiness waits outside the rootless mutation transaction.
  The helper releases the per-user lock after `podman compose up -d`, so
  independent applications can warm in parallel. Short Podman control-plane
  observations that determine repair, especially an in-container DNS probe, take
  a shared lock on the same per-user lock file. Mutations take its exclusive
  side. This preserves parallel observations while preventing a control-plane
  timeout during another project's mutation from being misclassified as broken
  DNS. Reacquire the exclusive lock only for repair. Distinguish a confirmed
  in-container lookup miss from an indeterminate observation: Podman query
  failure, outer timeout, signal, or missing probe target must settle or retry
  within the existing service bound and must not authorize repair or destructive
  cleanup. Treat the upstream `compose up` invocation itself as indivisible: it
  can wait internally on `depends_on` health between mutations, and terminating
  it at a `podman wait` process is not a transaction boundary. Never replay a
  partial provider invocation as dependency waves. If shorter mutation windows
  are required, use a provider/native graph that exposes create, dependency
  wait, and start as explicit operations instead of inferring phases from its
  process tree.
- Treat `preStart` as mutation-capable unless the module grows an explicit
  non-mutating hook contract. There is no schedulable bootstrap unit. The main
  helper runs local-image loading and `preStart` under an internal
  `timeoutBootstrapSeconds` sub-deadline, then continues under the same lock and
  marker into project cleanup and its one Compose invocation. File staging
  remains parallel.
- A failed mutation is not complete when `podman compose up` exits. Project
  rollback remains inside the same transaction and must prove absence with fresh
  inventory queries. Proven rollback clears the marker; uncertain cleanup
  records a durable per-user dirty marker and blocks later mutation. Generated
  preflight may prune Aardvark files that fresh Podman inventory proves stale,
  but it must not reload every active rootless network as a cleanup side effect:
  a repaired project has no running containers, while a retained project must
  remain undisturbed. Never directly control the shared Aardvark daemon.
- Serialization is not crash atomicity. A killed helper can release its flock
  while Podman's database, conmon/FUSE state, Netavark networks, or Aardvark
  files still describe an incomplete mutation. Every mutation writes a durable
  per-project in-progress marker. Ordinary lock acquisition checks the current
  boot/inventory preflight stamp and fails closed on abandoned or dirty state;
  it never performs broad repair inline.
- A generated per-user runtime preflight is a hard dependency of every main
  compose and image-pull mutation unit. It reconciles stale/failed project
  containers and Aardvark configuration before the graph releases live
  mutations. Parallel staging and unlocked readiness remain intact. A boot-ID
  plus inventory-token stamp makes the healthy path metadata-only; abandoned
  markers or a failed preflight invalidate the stamp. Preflight failure blocks
  the whole user's start wave rather than allowing a partially poisoned runtime
  to cascade across projects.
- Pre-activation image pulling is a non-disruptive preparation transaction, not
  an invocation of runtime preflight. It shares the rootless mutation lock for
  image-store safety, ignores a generation-stamp mismatch, and never queries or
  repairs live projects. If a durable dirty marker, required-preflight marker,
  or abandoned mutation exists, defer the pull to the activation graph. The
  generated image-pull unit remains ordered after the per-user preflight and is
  the fail-closed retry owner once runtime repair is safe. Preparation must also
  defer successfully when either its service lifecycle lock or the shared
  rootless lock is busy; bound both acquisitions so an old-generation helper
  cannot prevent installing the candidate generation that replaces it. Apply the
  same contract to Compose and Quadlet backends. Ordinary activation/runtime
  pulls remain blocking and fail closed.
- Network correction is evidence-scoped. Only a running service's confirmed
  lookup miss for a running declared peer can authorize a project-scoped Podman
  network reload. Preflight cleanup, a stale marker, or pruning an unattached
  Aardvark file never authorizes `podman network reload --all`.
- An active `start-in-progress` marker is never readiness evidence. A second
  start must fail as a concurrent lifecycle attempt rather than notify systemd
  that the project is ready. The verifier remains read-only and independently
  confirms the resulting project state. It retries bounded transient Podman
  state-query failures, treats `health=starting` as settling, and fails on
  `health=unhealthy` or missing expected services. A ready target must never
  succeed from container `State=running` alone when a healthcheck is present.
- Main compose units use `KillMode=mixed`. Rootless Podman's `conmon` and
  `fuse-overlayfs` processes inherit the unit cgroup, so `control-group` would
  send them the graceful stop signal alongside the helper and invalidate live
  container mounts. The helper owns graceful compose cleanup; systemd retains
  the whole-cgroup final SIGKILL boundary for a genuinely wedged stop.
- Before NixOS submits changed user-unit stop jobs, the Podman module drains
  changed active main units sequentially from the old control registry. Abort on
  the first failed drain and do not schedule later units. This containment
  boundary makes `KillMode=mixed` safe: systemd's later parallel batch sees
  already-stopped units rather than live sibling container cgroups. Missing
  legacy drain stamps mean one deliberate transition drain;
  `removalPolicy = "keep"` remains untouched.
- Generated service units call backend-specific stable helpers under
  `/etc/podman-compose/helpers`. Keep exact store-qualified helpers for
  pre-activation plans and other generation-explicit commands, but do not embed
  helper derivation paths in long-lived main/preflight unit definitions.
- Normal stop waits for the shared rootless mutation lock without a second
  helper deadline; systemd's `TimeoutStopSec` is the authoritative bound for the
  whole operation. Keep at least 240 seconds, or the larger instance readiness
  timeout, for the bounded compose command and cleanup reserve. An explicit
  helper lock timeout may be used for compatibility testing, but must fail
  closed and never run mutation unlocked.
- The mutation transaction is intentionally shorter than readiness. Do not hold
  it across long app warm-up, post-start hooks, or monitor polling. Health
  checks may report an active rootless mutation marker as settling, but only
  while the normal deploy health timeout is still running. Once systemd
  transitions and mutation markers have cleared, unhealthy containers are real
  failures.
- Treat activation admission as the rollback boundary. A preparation or
  transport failure before nixbot records activation admission leaves the
  current generation unchanged and must not trigger a snapshot switch. An
  admitted deploy failure may roll back only its own host. Ordinary failure on
  one host never rolls back successful peers; those hosts remain eligible for
  candidate-generation health checks.
- A per-service ready target requires only its verifier, while the verifier
  requires and orders after the main compose service and optional reconciler.
  This pulls the complete readiness graph into one systemd transaction without
  bypassing the main services' static start-lane edges. Each lane successor
  orders after the predecessor's ready target rather than its main service, so
  `startConcurrency` spans the full readiness boundary. Verifiers are read-only:
  they report stale stamps or unhealthy state and fail rather than restarting a
  service and creating a second lifecycle wave.
- Inspect compose project state with direct, label-filtered
  `podman ps -a
  --format json`. Do not add per-project monitor loops that
  repeatedly invoke the Python compose provider; project discovery uses the
  `com.docker.compose.project.working_dir` label.
- The control registry exports each auto-start main unit, ready target, managed
  root, working directory, expected Compose services, and target-local
  verification command. Deploy health compares one read-only `podman ps -a`
  snapshot per user with that declaration, then runs bounded local probes in
  parallel. Missing/exited containers and unusable origins are leaf-local
  failures; they do not change the managed root or siblings.
- `verifyCommand` is an explicit read-only argv list. When omitted for an
  instance with `exposedPorts.http`, generate a local HTTP probe that rejects
  connection failures and 5xx while accepting usable 1xx-4xx responses.
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

Bootstrap preparation is a separate phase from application readiness. Use
`timeoutBootstrapSeconds` only for measured local image-load or `preStart`
costs; do not spend `timeoutReadySeconds` on preparation and do not add restart
loops to compensate for a short bootstrap deadline.

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

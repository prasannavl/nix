# Podman Compose

Use this model for container workloads that should run as rootless Podman stacks
on a host.

## What It Provides

- staging of compose files into a working directory
- generated user services for stack lifecycle
- env-secret injection
- firewall derivation from exposed ports
- nginx and Cloudflare Tunnel metadata derivation
- duplicate-subnet detection for declared compose networks
- duplicate exposed-port detection for declared host port/protocol pairs
- deploy-time restart and recreate behavior

The shared logic lives in `lib/podman-compose/default.nix` and
`lib/podman-compose/helper.sh`.

## Declaration Shape

```nix
services.podman-compose.<stack> = {
  user = "app";
  stackDir = "/var/lib/app/compose";
  servicePrefix = "app-";

  instances.<name> = {
    bootTag = "0";
    recreateTag = "0";
    imageTag = "0";

    source = ''
      services:
        app:
          image: docker.io/library/nginx:latest
    '';
  };
};
```

When at least one stack is declared, the module also enables Podman and the
required runtime packages.

## Source Patterns

Use one of these shapes:

- attrset `source`: when Nix should render the compose structure
- inline YAML `source`: for small host-local stacks
- file-backed `source`: when the main compose file should stay in the repo
- directory-backed `files`: when the stack is a directory tree with multiple
  compose fragments
- inline `files` overrides: when the base compose file is stable but host-local
  overlays or `.env` files are generated in Nix

## Exposed Ports

`exposedPorts` is the shared ingress metadata for a stack. It can drive:

- Podman port publishing
- firewall openings
- nginx reverse-proxy vhosts
- Cloudflare Tunnel ingress
- rate limiting

Typical shape:

```nix
exposedPorts.http = {
  port = 12000;
  openFirewall = true;
  nginxHostNames = ["app.example.com"];
  cfTunnelNames = ["app.example.com"];
  rateLimit = null;
};
```

Compose `ports` entries should omit the host address unless the bind address is
part of the intended behavior. Use `12000:8080` for the default all-interface
bind, `127.0.0.1:12000:8080` for loopback-only listeners, and a specific local
address only when the service truly requires that interface. Do not use a
service-registry target address as a host bind address; target addresses may
point at another endpoint group during migrations.

## Lifecycle Tags

- `bootTag`: stop and start the stack
- `reloadTag`: reload the stack when native reload is enabled
- `recreateTag`: stop and start the stack; under policies that allow recreate,
  force recreate once for each new tag value
- `imageTag`: run the image-pull path before the stack starts and, under `auto`
  or `recreate`, fold image changes into recreate drift

These are manual lifecycle knobs. Toggle the value when you want the behavior.

`state = "running" | "stopped"` is the desired runtime state. Use
`state = "stopped"` when an instance should stay declared but be kept inactive
by automatic reconciliation. Stopped units still have a generated manual
start/stop surface; runtime files are staged on start and cleaned after stop.
That cleanup is intentional even though the declaration remains present: it
prevents stale staged files from surviving generation shifts. Starting the unit
again stages the current generation before `podman compose up`. Declaration
removal is a separate path controlled by `removalPolicy`.

`autoStart` controls cold-start behavior for otherwise running instances.

`removalPolicy = "inherit" | "keep" | "stop" | "delete" | "delete-all"` controls
what happens when the declaration is removed. Instances default to `inherit`;
the stack default is `delete`. `keep` leaves the old workload alone for manual
takeover. `stop` stops compose containers without removing compose objects or
generated files. `delete` runs `podman compose down` and cleans generated
runtime files. `delete-all` also runs compose down with volumes and deletes
managed staged dirs under the compose working directory.

The helper keeps generated runtime files under the compose working directory and
helper state in `.podman-compose/state.json`. A re-declared instance can proceed
when that state has the same generated service identity and working-directory
stamp. Set `adopt = true` for one deploy when deliberately taking over an
existing working directory with missing or mismatched helper state. Adoption
force-recreates containers so the adopted runtime starts from the declared
compose shape, independent of `reconcilePolicy`.

`timeoutReadySeconds` controls the generated user-manager wait for the compose
unit to leave transitional states such as `activating`, `deactivating`, or
`reloading`. It defaults to 120 seconds at the stack level and can be overridden
per instance.

`startStateStallSeconds` optionally bounds how long the helper allows expected
containers to remain non-running during `podman compose up`. Leave it unset
unless a healthy startup path has a measured reason for a different guard.

## Operator Control

Hosts with Podman compose instances install `podman-composectl`, a generated
control wrapper keyed by the generated systemd user service name without
`.service`.

```sh
podman-composectl list
podman-composectl gap3-stalwart status
podman-composectl gap3-stalwart restart
podman-composectl gap3-stalwart link
podman-composectl gap3-stalwart logs --tail=100
podman-composectl gap3-stalwart clean
```

`start`, `stop`, `restart`, `reload`, and `status` forward to the owning user's
systemd user unit. `link`, `clean`, `verify`, and `logs` call the
generation-specific helper with the right metadata environment.

`link` stages the current generation's runtime files without starting
containers. This is an explicit debugging hatch: staged config and secret
material stays in the working directory until `clean` or a normal unit stop
cleanup removes it.

## Instance Subnets

Set `subnet` when an instance declares a stable default-network subnet in its
compose source.

```nix
services.podman-compose.example.instances.app = {
  subnet = "10.89.10.0/24";
  source = ''
    networks:
      default:
        ipam:
          config:
            - subnet: 10.89.10.0/24
    services:
      app:
        image: docker.io/library/nginx:latest
  '';
};
```

The module asserts that declared `subnet` values are unique across all
configured `services.podman-compose` instances. It does not generate compose
network YAML by itself; the option records the subnet for clash detection.

The module also asserts that declared `exposedPorts` do not reuse the same host
port for the same protocol.

## Runtime Model

For each instance, the generated service:

- stages managed files into the working directory
- removes managed file-versus-directory conflicts before restaging
- runs supervised `podman compose up -d --remove-orphans`
- verifies that containers reached a healthy running state
- runs `postStart` hooks after compose readiness succeeds
- stays attached with a monitor loop so systemd can observe failure

Readiness is owned by the helper/monitor process only. Generated units use
`NotifyAccess = "all"`, and helper-spawned `podman` commands scrub systemd
notify/watchdog environment so conmon or container children cannot satisfy
readiness or become the effective `Type=notify` authority.

Failed starts must leave the compose project retryable. The helper owns
`podman compose up` supervision and derives its deadline from the effective
systemd `TimeoutStartSec`, keeping a small cleanup reserve before systemd would
kill the helper. If compose output shows a fatal start error, the helper should
terminate compose early instead of waiting for the full timeout.

Stop paths are also helper-supervised against the unit's own timeout budget.
`compose stop`, `compose down`, and `compose down --volumes` derive their
deadline from `TimeoutStopSec`; generated compose units set it explicitly so the
helper has a predictable cleanup window instead of relying on the user manager
default.

Failed-start cleanup removes only compose project containers and networks,
including expected compose container names left behind by partial Podman storage
state. It does not remove volumes or managed data directories; persistent data
recovery remains an operator decision. `ExecStopPost` may call the same cleanup
after a systemd timeout or helper crash, but it is a backstop rather than the
primary failure path.

The user-service switching path is handled by
[`docs/systemd-user-manager.md`](./systemd-user-manager.md).

During user-manager reconciliation, Podman also supplies a provider verifier.
The verifier checks staged runtime files, native-reload staged files, generated
env-secret files, restart-class helper state, and pending recreate-class state.
If an already-active unit skipped start but still has stale runtime material,
the user-manager restarts it once and only records the new metadata as applied
after Podman verification passes.

## Secret Model

Use file-backed environment secret injection. Do not bake secret values into
images or repo-tracked compose files.

## Where To Put Things

- host declarations: the host's imported service module, commonly
  `hosts/<host>/services.nix` or `hosts/<host>/services/default.nix`
- host-local compose trees: `hosts/<host>/compose/<stack>/`
- shared module logic: `lib/podman-compose/`

## Quick Links

- [`docs/systemd-user-manager.md`](./systemd-user-manager.md)
- [`docs/nginx.md`](./nginx.md)
- [`docs/deployment.md`](./deployment.md)

## Detailed Reference

The sections below cover declaration patterns, examples, and operational edge
cases.

## Declaration Patterns

The module supports a few different ways to declare compose content.

### 1. Render YAML from a Nix attrset

This is useful when you want Nix expressions to build the compose structure
directly:

```nix
services.podman-compose.example.instances.control-panel = {
  source = {
    services.control-panel = {
      image = "docker.io/example/control-panel:latest";
      restart = "unless-stopped";
      environment.APP_STACKS_DIR = "/var/lib/example/compose";
    };
  };
};
```

This is the pattern for a small Nix-rendered admin service.

### 2. Inline YAML text in `source`

This is the simplest pattern for small services and generated definitions:

```nix
services.podman-compose.example = {
  user = "app";
  stackDir = "/var/lib/app/compose";

  instances.web = {
    source = ''
      services:
        open-webui:
          image: ghcr.io/open-webui/open-webui:main
          ports:
            - "0.0.0.0:13000:8080"
    '';
  };
};
```

This is the pattern for a small host-local stack.

### 3. Point `source` at a compose file in the repo

This is the right pattern when the main compose YAML already lives as a normal
file:

```nix
services.podman-compose.example.instances.service = {podmanSocket, ...}: {
  source = ./compose/service/docker-compose.yml;

  files.".env" = ''
    PODMAN_SOCKET=${podmanSocket}
  '';
};
```

This is the most common pattern when the main compose YAML already lives in the
repo.

### 4. Stage an entire compose directory with `files`

This is useful when a service is naturally a directory tree with multiple
compose fragments, env files, or companion config files:

```nix
services.podman-compose.example.instances.suite = {
  entryFile = [
    "docker-compose.yml"
    "weboffice/collabora.yml"
    "external-proxy/app.yml"
    "external-proxy/collabora.yml"
    "search/tika.yml"
  ];

  files = {
    "" = ./compose/suite;
  };
};
```

In this pattern:

- `files."" = ./compose/suite;` stages the whole directory tree into the working
  directory
- `entryFile` tells the module which staged compose files to pass to
  `podman compose -f ...`
- when `entryFile = null`, files-only stacks automatically derive staged default
  compose files such as `compose.yml` or `docker-compose.yml`; set `entryFile`
  explicitly when the stack uses a custom file order or additional fragments

### 5. Override or add files inline with `files`

You can also keep the main compose file as a repo path and override companion
files inline:

```nix
services.podman-compose.example.instances.media = {
  source = ./compose/media/docker-compose.yml;

  files = {
    ".env" = ''
      APP_HTTP_PORT=2283
      DB_USERNAME=postgres
      DB_DATABASE_NAME=app
    '';
    "hwaccel.ml.yml" = ./compose/media/hwaccel.ml.yml;
  };
};
```

This is the usual pattern when the base compose file should stay file-backed but
host-specific overlays, env files, or extra fragments should be generated in
Nix.

### When to use which

- Use an attrset `source` when Nix should generate the compose structure.
- Use inline text when the service is short and host-specific.
- Use a file-backed `source` when the main compose YAML should stay as a normal
  file in the repo.
- Use directory-backed `files` when the service is really a compose tree, not a
  single file.
- Use inline `files` overrides when the base compose file is stable but host
  overlays should still be generated declaratively.

## Generated Runtime Model

For each compose instance, the module generates a systemd user service that:

- stages rendered compose files into the working directory
- removes manifest-managed file-versus-directory conflicts before restaging, so
  bind-mounted runtime paths can safely change shape across deploys
- runs `podman compose up -d --remove-orphans`
- verifies that compose did not leave any container stuck in `Created` or
  another non-running state
- only reports systemd startup success after that verification passes
- stays attached with a provider-agnostic monitor loop so systemd can observe
  runtime failure even when the external compose provider does not implement
  `wait`
- supports `systemctl --user reload <unit>` through a helper-level lifecycle
  lock so the monitor does not observe intentional transient reload states
- runs `podman compose down` on stop

The main generated service keeps only narrow helper state:

- the helper stores the last successfully applied `recreateTag` in the compose
  working directory so force-recreate does not replay on later boots
- boot-time startup is gated behind `systemd-user-manager-ready.target`, so the
  main compose services do not start until the per-user reconciler has run once

## Tags

- `bootTag`:
  - default is `"0"`
  - when the declared value changes, the main generated compose unit is treated
    as changed
  - active stacks restart through the normal managed-unit path
- `reloadTag`:
  - default is `"0"`
  - when native reload is enabled, a declared value change reloads active stacks
    through `systemctl --user reload`
  - restart triggers still win if restart and reload inputs change together
- `recreateTag`:
  - default is `"0"`
  - when the declared value changes, the main generated compose unit is treated
    as changed
  - active stacks restart through the normal managed-unit path
  - under `auto` or `recreate`, if the tag is nonzero and differs from the last
    successful helper state, the next start uses
    `podman compose up --force-recreate`
  - under `restart`, it restarts the unit without force-recreating containers
- `imageTag`:
  - default is `"0"`
  - generates a separate oneshot image-pull user unit
  - the main compose unit starts after that pull unit when image refresh is
    enabled
  - the tag participates in `recreateStamp`; under `auto` or `recreate`, a tag
    change restarts the main unit and the helper uses
    `podman compose up --force-recreate`
  - under policies that do not allow recreate, changed images are consumed on
    the next explicit start/restart

Operationally, the intended manual toggles are between `"0"` and `"1"`, though
any new string value works.

## Reload

Reload is available for manual operator use. The default method is restart:

```nix
reload.method = "restart";
```

That path takes the lifecycle lock, runs `podman compose down` with the current
compose context, cleans old manifest-managed runtime files, stages the desired
runtime tree, starts the stack, verifies health, and then releases the monitor.

Native reload is opt-in and currently signal-based:

```nix
reload = {
  method = "signal";
  signal = "HUP";
  services = ["nginx"];
  trigger.dirs = ["conf.d"];
};
```

`reload.trigger.dirs` may only name declared `dirs` entries or staged directory
sources. `reload.trigger.externalFiles` may name explicit staged file entries
that are external to the container mount contract; the module rejects files that
are detected as exact single-file bind mounts. Directory mounts, such as
`./conf.d:/etc/nginx/conf.d`, can safely expose replaced child files to a
process that reopens paths during native reload. For native reload, the helper
stages new desired files and updates the runtime manifest before signaling;
stale files under the reload dirs are pruned only after the signal path verifies
cleanly.

Use `recreate.trigger.files` for explicit staged files whose changes require
container recreation, such as files consumed through exact single-file bind
mounts that cannot be detected from structured compose data. Automatically
detected exact single-file bind mounts are added to the same effective
recreate-file list. A file may not be both reload-class and recreate-class; the
module rejects overlaps with `reload.trigger.dirs` or
`reload.trigger.externalFiles`.

Deploy-time reload triggers are wired through `systemd-user-manager` for
reload-capable instances. If only files under `reload.trigger.dirs` change, the
dispatcher daemon-reloads the user manager and calls `systemctl --user reload`
instead of old-world stop plus new-world start. Restart and recreate triggers
still win when non-reload-safe inputs change.

## Drift Actions

Declarative drift is classified by the narrowest automatic action that can make
the running stack match the declaration:

- reload-class drift:
  - `reloadTag`
  - files under `reload.trigger.dirs`
  - explicit `reload.trigger.externalFiles`
- restart-class drift:
  - `bootTag`
  - ordinary staged runtime files and directory metadata that are not reload
    triggers
  - `envSecrets` and `fileSecrets` source content and staging permissions
  - generated unit wiring and other non-container-shape inputs
- recreate-class drift:
  - `recreateTag`
  - `imageTag`
  - compose files, compose entry selection, and expected compose-service shape
  - explicit `recreate.trigger.files`
  - automatically detected exact single-file bind-mounted staged entries
  - `envSecrets` and `fileSecrets` mount/env-file shape, including secret keys,
    env-var names, target compose services, mount paths, and generated override
    files

Internally, the module builds one action payload per action class: `reload`,
`restart`, and `recreate`. Staged files are first classified into those
payloads, with recreate-class files excluded from reload/restart payloads. The
corresponding `reloadStamp`, `restartStamp`, and `recreateStamp` are hashes of
those action payloads.

`systemd-user-manager` receives restart/recreate inputs only through
`restartTriggers` and `stampPayload`; reload-only inputs stay only in
`reloadTriggers`. That lets a reload-only change reload an active stack without
poisoning the helper's recreate state for a later start.

`reconcilePolicy` controls how those action classes are consumed:

- `auto` is the normal smart mode: reload-class drift reloads, restart-class
  drift restarts, and recreate-class drift force-recreates.
- `restart` restarts for reload-class, restart-class, and recreate-class drift.
  The helper uses plain `podman compose up`; it does not force-recreate
  containers.
- `recreate` is a blunt manual mode: any declarative drift restarts the managed
  unit and the helper runs `podman compose up --force-recreate`.

Policy-only transitions are directional. `auto -> restart`, `auto -> recreate`,
`recreate -> auto`, and `recreate -> restart` do not by themselves stop the
managed unit. `restart -> auto` and `restart -> recreate` stop/start the managed
unit once so pending recreate-class drift from restart mode is consumed with
`podman compose up --force-recreate`. Podman expresses this to
`systemd-user-manager` with provider-owned transition tokens; the lower-level
manager does not know Podman policy names.

## What Changes Trigger

- `bootTag` change:
  - changes the main generated user unit restart stamp
  - only the declared `bootTag` value participates in that tag-specific stamp
  - active stacks restart through the normal managed-unit path
- `reloadTag` change:
  - changes the main generated user unit reload stamp when native reload is
    enabled
  - active stacks reload on deploy
- `recreateTag` change:
  - changes the main generated user unit restart stamp
  - causes a managed stop/start cycle for active stacks during deploy
  - under `auto` or `recreate`, forces container recreation once per new nonzero
    tag value
  - under `restart`, restarts without force-recreating containers
- `adopt = true`:
  - allows missing or mismatched helper identity state in an existing working
    directory
  - changes the main generated user unit restart stamp
  - force-recreates containers on start so the adopted runtime matches the
    declaration
  - should be removed after the takeover deploy
- `imageTag` change:
  - changes the separate generated image-pull user unit
  - changes `recreateStamp`
  - under `auto`, restarts the main compose unit and forces container recreation
  - under `restart`, restarts the main compose unit without force-recreating
    containers
  - under `recreate`, restarts the main compose unit and forces container
    recreation
- ordinary non-reload-safe staged `files`, secret source content, or generated
  unit change:
  - changes the main generated user service and restart stamp
  - active stacks restart on deploy
  - inactive stacks are started during reconcile unless disabled or masked
  - `state = "stopped"` keeps declared stacks inactive during reconcile
- compose/container shape change:
  - changes `recreateStamp`
  - under `auto`, active stacks restart and the helper uses
    `podman compose up --force-recreate`
  - under `restart`, active stacks restart without force-recreating containers
  - under `recreate`, active stacks restart and force-recreate
  - includes compose files, entry-file selection, exact single-file bind-mounted
    staged entries, `envSecrets`, `fileSecrets`, and `imageTag`
- reload-safe `files` under `reload.trigger.dirs`:
  - change the main generated user service reload stamp
  - active stacks reload on deploy when `reload.method = "signal"`
  - inactive stacks are still handled by normal reconcile
- explicit `reload.trigger.externalFiles`:
  - must name declared staged file entries
  - are rejected when the same entries are recreate-class files
  - otherwise participate in the reload stamp as external trigger files
  - compose-consumed files such as `.env` do not update container environment or
    interpolation until restart/recreate
- explicit `recreate.trigger.files`:
  - must name declared staged file entries
  - change `recreateStamp`
  - under `auto`, active stacks restart and the helper uses
    `podman compose up --force-recreate`
  - under `restart`, active stacks restart without force-recreating containers
  - under `recreate`, active stacks restart and force-recreate
  - are rejected if they also match native reload triggers
- plain reboot:
  - starts the main compose user service
  - runs the image-pull helper first when image refresh is enabled
  - does not replay `recreateTag`

## Restart Trigger Coverage

- `source` content is covered. When the compose source changes, the rendered
  store path changes, and that path is part of the main restart stamp.
- `files` content is covered. For normal entries, rendered or copied store paths
  participate in the restart stamp. For reload-capable entries under
  `reload.trigger.dirs` or `reload.trigger.externalFiles`, those paths
  participate in the reload stamp instead. Exact single-file bind-mounted staged
  entries also participate in the recreate stamp, because replacing the host
  file can otherwise leave the container attached to the old inode.
- `entryFile` selection is covered because it changes the generated user unit.
- Generated unit configuration is covered. Changes to service environment,
  dependencies, or other generated unit wiring change the restart stamp through
  the rendered systemd unit.
- `envSecrets` mapping structure is covered by the recreate stamp. Adding,
  removing, or changing `envSecrets.<composeService>.<ENV_VAR>` is container
  shape drift, not restart-safe content drift.
- `envSecrets` source content is covered for repo-managed age secrets. When the
  configured runtime path maps back to `config.age.secrets.<name>.file`, that
  encrypted source file hash participates in the restart stamp.
- `fileSecrets` mapping structure and generated mount wiring are covered by the
  recreate stamp. Per-entry permissions and repo-managed age secret source
  hashes are covered by the restart stamp.

## Derived Metadata

`services.podman-compose.<stack>.instances.<name>.exposedPorts` is the source of
truth for compose-managed port metadata.

It drives:

- host firewall openings when `openFirewall = true`
- derived nginx reverse-proxy metadata
- derived Cloudflare Tunnel ingress metadata

For ports exposed through the shared nginx reverse proxy, the same metadata also
owns the proxy rate-limit policy. The default is a per-client limit keyed by
`$binary_remote_addr` with:

- `rate = "10r/s"`
- `burst = 20`
- `nodelay = true`
- `statusCode = 429`

Override or disable it per exposed port:

```nix
exposedPorts.http = {
  port = 12000;
  nginxHostNames = ["app.example.com"];

  rateLimit = {
    rate = "30r/s";
    burst = 60;
  };
};

exposedPorts.metrics = {
  port = 19090;
  nginxHostNames = ["metrics.example.com"];
  rateLimit = null;
};
```

## Secret Injection

Two secret models are supported.

### envSecrets

Per-compose-service env-file injection. Each compose service gets a generated
env_file the image entrypoint picks up.

```nix
envSecrets.<composeService> = {
  PG_PASSWORD = "/run/agenix/pg-password";
  API_KEY     = "/run/agenix/api-key";
};
```

The module generates an override file that adds `env_file` wiring, so secrets
can be injected without replacing the image entrypoint or command.

### fileSecrets

File-backed secrets staged into
`<workingDir>/.podman-compose/file-secrets/<name>` and auto-mounted read-only
into target compose services.

```nix
fileSecrets."server.key" = {
  file  = "/run/agenix/my-server-key";
  mode  = "0600";
  user  = 1000;
  group = 1000;
  scope = "container";

  # Optional mount controls:
  mount = true;                    # default
  mountPath = "/run/secrets/key";  # default: /run/secrets/<name>
  services = [ "postgres" ];       # default: source.services keys, else instance name
  readOnly = true;                 # default
};
```

Bare string shorthand `fileSecrets."X" = "/run/agenix/X";` coerces into
`{ file = "/run/agenix/X"; }` with default permissions (mode 0400, owner
unchanged, host scope) and mounts at `/run/secrets/X`.

The module generates an additional compose override file for mounted
`fileSecrets`. When `services = null`, attrset-shaped `source.services` keys are
used as the target compose services. String/path compose sources fall back to
the podman-compose instance name. Set `services = [ ... ]` when the compose
service name differs, and set `mount = false` for stage-only secrets that are
mounted manually from the main compose source.

The `.podman-compose/` working-directory prefix and generated override file
names are reserved for the module's runtime files.

### dirs

Managed directories for bind mounts or restrictive parent directories. Relative
`dirs` keys are resolved under the compose working directory:

```nix
dirs."conf.d" = {
  mode = "0750";
  user = 1000;
  group = 1000;
  scope = "container";
};
```

Absolute keys manage host paths directly, which is the preferred shape for
external data directories:

```nix
dirs."/var/lib/example" = {
  mode = "0700";
  user = 1000;
  group = 1000;
  scope = "container";
  once = false;
};
```

The helper runs as the stack user, so the parent of an absolute `dirs` path must
already exist and be searchable/writable by that user. The stack root created by
the module's tmpfiles rule is the intended parent for host-local service data.

Directory modes must include an execute/search bit. For example, use `0750` for
an owner-readable private config directory; `0640` is a file mode and makes the
directory non-traversable.

By default, ownerless dirs without staged children are create-only: the helper
creates and initializes them when missing, but preserves existing dirs. Set
`once = false` to reconcile mode and ownership on every helper run. Dirs with an
explicit `user` or `group`, and dirs that contain staged files, default to
managed behavior.

For managed dirs, the helper temporarily prepares them for restaging or cleanup,
then reapplies the declared mode/owner afterward. This keeps restarts idempotent
while allowing the final directory bind mount to avoid world traversal bits.

### Ownership and permissions (applies to `dirs`, `files`, and `fileSecrets`)

Each staged entry accepts:

- `mode` - octal mode string (e.g. `"0644"`) or `"none"` to preserve the copied
  source mode; file default `"none"`, secret default 0400, directory default
  0750
- `user`, `group` - name or numeric id; null means "leave as stack user"
- `scope` - `"host"` (default) or `"container"`; with `"container"`, the helper
  runs `chmod` and `chown` via `podman unshare` so mode and numeric uid/gid are
  applied in the rootless user namespace (container 1000 -> host SUB+999)

Container-scoped ownership requires numeric `user` and `group` when owner fields
are set because the rootless user namespace has no name resolution. This is
enforced by assertion at evaluation time.

Secret rotation caveat:

- `envSecrets` and `fileSecrets` files are restaged on `start`
- repo-managed age secret source file changes are included in the restart stamp
  when the secret runtime path maps back to `config.age.secrets`
- secret files outside `config.age.secrets` still only track the configured
  path; bump `bootTag` when those files need a managed restart
- bump `recreateTag` only if you also want the next start to use
  `podman compose up --force-recreate`

## Deployment And Sequencing

On host deploy:

1. systemd reloads the affected user manager once
2. changed bridge units stop
3. changed bridge units start in the new generation
4. reload-only bridge units are reloaded after the user manager sees the new
   unit definitions
5. the reconciler starts inactive managed units in the new generation

That means:

- Podman stacks must never make boot activation fail; boot-time ordering is
  handled after activation through `systemd-user-manager`'s normal boot unit and
  `systemd-user-manager-ready.target`
- boot-time service startup waits for `systemd-user-manager-ready.target`, which
  the reconciler starts after a successful per-user apply
- `dry-activate` logs the starts it would perform, but does not actually mutate
  the running user services
- `imageTag` is implemented as a normal helper unit plus recreate-stamp input;
  the image pull itself is not a reconciler action
- `bootTag` and `recreateTag` are expressed as changes to the main unit itself
- `removalPolicy = "keep"` maps to the lower-level user-manager takeover
  behavior; it does not keep the generated unit in the new system generation,
  and re-declaring that working directory requires matching
  `.podman-compose/state.json` identity state or a one-time `adopt = true`
- rootless stack users get a system-level `podman-rootless-idmap-migrate-<user>`
  one-shot before their systemd-user-manager dispatcher; it runs
  `podman system migrate` only when `/etc/subuid` and `/etc/subgid` exist and
  Podman's current id map is still a stale single-id map

## What A Host Must Provide

For each stack in the host's service module:

- `user`
- `stackDir`
- one or more `instances`
- either `source` or `files` for each instance
- optional `bootTag`
- optional `reloadTag`
- optional `recreateTag`
- optional `imageTag`
- optional `longRunning = false` for run-to-completion stacks where all
  containers exiting with code 0 should be service success
- optional `reload` policy for manual reload behavior
- optional `subnet` when the compose source declares a stable default-network
  subnet
- optional `dependsOn`, `wants`, `envSecrets`, `exposedPorts`,
  `serviceOverrides`

## How To Create A New Compose Service

1. Add or update the host's imported service module.
2. Declare a stack under `services.podman-compose.<stack>`.
3. Add one or more instances.
4. If the service needs ingress, define `exposedPorts`.
5. If it needs secrets, define `envSecrets`.
6. Deploy the host.

## FAQ

### What happens when I change compose source?

The main generated user unit changes. If the stack was active, the deploy-time
bridge restarts it. If it was inactive but still startable, reconcile starts it.

### What happens when I bump `recreateTag`?

The main generated unit changes, so active stacks restart through the normal
managed-unit path. Under `auto` or `recreate`, if the new tag is not `"0"` and
differs from the helper state recorded during the last successful
force-recreate, the helper uses `podman compose up --force-recreate` and records
the new tag. Under `restart`, the tag restarts the unit but does not
force-recreate containers. Later boots with the same applied tag do not force
another recreate.

### What happens when I bump `bootTag`?

The managed unit stamp changes. If the stack was active, the normal
systemd-user-manager reconciliation path restarts the main compose unit. This is
keyed to the declared `bootTag` value itself, not helper script path or other
generated unit churn.

### What happens when I bump `reloadTag`?

For native-reload-capable instances, the managed unit reload stamp changes. If
the stack was active and no restart trigger also changed, systemd-user-manager
reloads the main compose unit. If native reload is not enabled, `reloadTag` has
no effect.

### What happens when I bump `imageTag`?

The separate image-pull unit changes, and the tag participates in the generated
drift stamps. Under `reconcilePolicy = "auto"`, image drift is recreate-class:
systemd-user-manager restarts the main compose unit, the pull unit runs first,
then the helper starts with `podman compose up --force-recreate`. Under
`reconcilePolicy = "restart"`, image drift still restarts the main compose unit,
but the helper uses plain `podman compose up` instead of force-recreating
containers. Under `reconcilePolicy = "recreate"`, any drift, including
`imageTag`, force-recreates. Image pull reads store-backed compose files
directly; runtime files and secrets are staged once by the main start path.

### Why didn't a secret rotation restart my service?

For repo-managed age secrets, it should. The podman module maps configured
runtime paths back to `config.age.secrets` and includes the encrypted source
file hash in the restart stamp. If the secret path is not represented in
`config.age.secrets`, the restart stamp can only track the configured path and
mapping; bump `bootTag` to force the normal reconcile restart path.

### Does boot gating behind `systemd-user-manager-ready.target` create a deadlock?

No. That target only gates automatic boot startup. The reconciler still talks to
the Podman unit directly with `systemctl --user start` or `restart` during
apply, then starts `systemd-user-manager-ready.target` after a successful run.

### What does `dry-activate` show for Podman stacks?

It runs the `systemd-user-manager` preview path. That means you get log lines
for the managed unit starts it would perform, but no actual compose action is
run.

### If a stack is intentionally inactive, do tag bumps wake it up?

Only when it is still managed as desired-running. `state = "stopped"` keeps it
inactive, and `autoStart = false` suppresses cold-start of an inactive unit. If
the stack was already active when a managed restart-class change happens, it can
still be stopped and restarted unless it has been moved to stopped state.

### Does `imageTag` rebuild build-only services?

Not by itself. `imageTag` uses `podman compose pull`, so build-only services may
need an explicit build flow if image refresh semantics need to cover them too.

## Further Reading

- `docs/services.md`: Native service pattern for non-container workloads.
- `docs/systemd-user-manager.md`: Deploy-time user-service bridge module used by
  `lib/podman-compose/default.nix`.
- `docs/incus-vms.md`: Incus guest lifecycle (uses the same lifecycle tag
  conventions).
- `docs/deployment.md`: Deploy architecture and secret model.

## Source Of Truth Files

- `lib/podman.nix`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/systemd-user-manager/default.nix`
- the host service module that declares `services.podman-compose.<stack>`
- `hosts/nixbot.nix`

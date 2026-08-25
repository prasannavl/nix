# Podman Quadlet Backend

## Decision

`services.podman-compose` keeps one Compose-shaped declaration contract. A stack
or instance selects `backend = "compose" | "quadlet"`; changing the backend does
not require rewriting `source`, `files`, secrets, hooks, or service metadata.
Quadlet is the module default; stacks or instances that require the
compatibility backend select `backend = "compose"` explicitly.

The backends intentionally diverge below that declaration boundary:

- Compose keeps metadata schema v11, `podman-compose-helper`, runtime state,
  rootless runtime preflight, and the deploy image-pull plan unchanged.
- Quadlet is a build-time translation into native `.container`, `.network`, and
  `.image` units. Systemd and Quadlet own runtime lifecycle, dependencies,
  readiness, restart policy, image acquisition, and cleanup. Small stateless
  source helpers perform Nix-owned staging and hook execution from explicit
  systemd arguments; no helper reads compiler output or runtime metadata, and no
  `.podman-compose/state.json` is written.

The checked-in shell ownership is deliberately limited to five source files:

- `helper.sh` contains backend-neutral Podman host bootstrap only; currently it
  provides the rootless ID-map/storage migration command.
- `composectl.sh` is the shared operator control plane for both backends and
  owns the internal activation-time changed-unit drain command.
- `compose-helper.sh` contains the existing metadata-driven Compose lifecycle,
  state, reconciliation, and per-instance image-pull implementation.
- `quadlet-helper.sh` contains only stateless, argv-driven `stage` and `hook`
  commands used by generated systemd units.
- `image-helper.sh` fans out the Compose deploy image-pull plan and delegates
  each instance pull to `compose-helper.sh`.

Do not move Compose metadata or lifecycle policy into the shared, Quadlet, or
image helpers. Do not add a Quadlet image fan-out path: native `.image` units
already own image acquisition.

The public graph remains stable for callers:

```text
<user>-managed.target
  Wants -> <name>-ready.target
              Requires -> <name>-verify.service
              Requires -> <name>.service       # Quadlet
              <name>-verify.service
                Requisite -> <name>.service    # Quadlet, never pulls it in
```

For Quadlet, generated containers use `[Install] RequiredBy=<name>.service`,
`Before=<name>.service`, and `PartOf=<name>.service`. The generator therefore
materializes the dynamic container set as native systemd dependencies without
importing compiler output into Nix evaluation. Containers require the fixed
`<name>-stage.service`; referenced `.network` and `.image` units add their own
native dependencies. Every private native unit uses `StopWhenUnneeded=yes`, so a
failed public activation automatically unwinds containers that already started,
then their network/image dependencies and staging. `PartOf=` continues to own
normal public stop/restart propagation.

## Build-Time Compilation Boundary

Compose-to-Quadlet translation is a normal Nix build, not Nix evaluation:

1. Nix passes the existing Compose entry files and a small JSON compiler input
   to a hermetic Python/PyYAML derivation.
2. The compiler parses Compose YAML, interpolates values per file, merges the
   resulting models in order, validates the supported subset, and emits Quadlet
   source files. Mapping keys are never interpolated.
3. It also emits `report.json`, containing only unit paths, container names, and
   image classifications needed by the later per-user collision check.
4. Nix evaluation never imports the report. Runtime services never read it.

This avoids IFD, keeps every existing Compose source authoritative, and leaves
our layer responsible mainly for translation and Nix-owned staging/hooks.

Quadlet files are installed as individual links under
`/etc/containers/systemd/users/<uid>/`. Do not replace that directory with one
store-directory link: Podman's generator would canonicalize `SourcePath` to the
store directory instead of the stable `/etc` path used for transition and
diagnostic evidence.

## Runtime Ownership

- Remote images use `.image` units with `Policy=newer`; store-built images use
  `Image=docker-archive:<store-path>` plus the archive's existing repository tag
  as `ImageTag`. `ImageTag` does not create an alias: Quadlet uses it to resolve
  the selected image already present in a file archive. The compiler reads only
  `manifest.json`, verifies explicit local-image tags against `RepoTags`, and
  requires compiler-discovered `nix-store:` archives to contain one unambiguous
  tag. Containers reference the `.image` file and use `Pull=never`, avoiding a
  second pull path.
- Compose `restart:` maps to systemd `[Service] Restart=`: `no -> no`,
  `always -> always`, `on-failure -> on-failure`, and
  `unless-stopped -> always`. Explicit `systemctl stop` still suppresses
  restart, which is the systemd equivalent of the intended stopped state.
- Healthchecked containers use `Notify=healthy` and `HealthOnFailure=kill`.
  Every generated container service also receives the instance
  `timeoutReadySeconds` as `TimeoutStartSec`, so Quadlet readiness is bounded by
  the declared contract instead of the user manager's shorter default. Public
  activation waits for native readiness, and systemd owns recovery.
- Quadlet's default rootless network-online dependency remains enabled. Do not
  add `DefaultDependencies=false` merely to reproduce the wrapper graph.
- The Nix-generated stage service expresses each ordered operation as an
  explicit systemd `ExecStart=` invocation of the checked-in, argv-driven
  `quadlet-helper.sh stage` command. It atomically stages non-compiler runtime
  files, file secrets, and environment-secret files and preserves the existing
  host vs container ownership rules. Reverse systemd ordering stops containers
  before stage cleanup. The stage uses the bootstrap timeout and performs
  cleanup through `ExecStopPost`, which covers failed starts as well as normal
  stops and removes both final destinations and temporary siblings.
  `podman-composectl link` restarts the public service; ordinary dependency and
  reverse ordering then stop containers, clean staging, restage, and restart the
  complete native graph without exposing a private unit through the control
  plane.
- `preStart`, `preStop`, and `postStart` use explicit systemd commands through
  `quadlet-helper.sh hook`. Systemd passes immutable build-time command file
  paths, avoiding multiline unit-file quoting; verification executes its
  configured argv directly. The helper contains no per-instance data and reads
  no runtime JSON metadata. Hook commands receive the same declared host PATH as
  Compose lifecycle hooks, so selecting a backend does not silently remove
  standard tools from an unchanged service hook. Quadlet accepts only
  best-effort `preStop` commands prefixed with `-`: systemd cannot cancel an
  already queued stop transaction when `ExecStop` fails, so hard veto hooks are
  rejected during evaluation instead of silently changing their Compose
  semantics.
- Quadlet keeps native private systemd unit names but preserves Compose's
  implicit runtime container identity, `<project>_<service>_1`; an explicit
  `container_name` still wins. The project name follows Compose precedence for
  `COMPOSE_PROJECT_NAME` from `.env`, otherwise using the normalized working
  directory basename. Existing service-local tools can therefore address the
  same container through either backend without per-instance rewrites or native
  runtime metadata.
- Activation uses the small control-registry `drainStamp` to stop a changed old
  public unit before switching generations. Native staging removes any stale
  Compose state while retaining the lifecycle-lock shell needed for clean
  rollback admission.

## Minimal Runtime Registry

Compose registry entries retain their existing fields. Quadlet entries contain
only operator/control-plane identity and fixed unit names:

- `user`, `uid`, `serviceName`, `backend`;
- public `unit`, `readyUnit`, and `managedUnit`;
- `autoStart`, `state`, `drainStamp`, and `removalPolicy`.

They do not contain helper metadata, a compiler report path, private unit or
container inventories, working-directory state, verification argv, image-pull
metadata, or timeout metadata. `podman-composectl expected-units` discovers the
generated private graph from systemd. It includes the fixed stage service and
accepts other private services only when their systemd `SourcePath` belongs to
`/etc/containers/systemd/users/<uid>/`; graph-query and provenance-query
failures are fatal. `expected-runtime` first requires the public unit to already
be active, starts a verify unit whose `Requisite=` cannot pull the public unit
in, rediscovers the same graph, and requires every persistent runtime unit to be
active. Successful inactive verifier oneshots are therefore excluded. Health
inspection is non-mutating and catches a container that exits independently
while the public aggregate remains active, without restoring runtime inventory
metadata. Quadlet containers also carry no repo-owned backend/inventory labels;
systemd's generated-unit provenance provides the declared identity.

On Quadlet-only systems, Compose runtime-preflight metadata and the
pre-activation Compose image-pull plan are absent. The immutable Compose helper
is retained only at the previous-generation `ExecStop=` compatibility path so a
single deploy can drain an active Compose provider before `/etc` switches; no
native steady-state unit calls it.

## Supported Compose Subset

The compiler deliberately supports the fleet's explicit subset:

- one or more services on one private default network, including subnet,
  aliases, and static IPv4 addresses;
- short-string ports, primitive exposed ports, bind mounts, environment,
  environment files, file secrets, and trusted-CA injection;
- string or primitive-argv commands and primitive-argv entrypoints;
- `depends_on` ordering and `service_healthy` dependencies;
- health checks, host aliases, capabilities, devices, supplementary groups, host
  IPC, memory/PID/shared-memory limits, read-only roots, tmpfs, ulimits,
  supported security options, restart declarations, user/group, and working
  directory;
- recursive Compose interpolation for unbraced and braced forms, including all
  `-`, `+`, and `?` empty/unset variants, lazy nested expressions, literal
  dollars, value-only interpolation, Compose `.env` quoting/comments/escapes,
  inherited or unresolved environment entries, Compose/YAML-1.2 boolean parsing,
  and ordered Compose-compatible multi-file merges; and
- explicit local image mappings plus compiler-discovered `nix-store:` image
  references, which must resolve at build time to an existing archive output
  directly under `/nix/store`.

Unsupported top-level or nested keys, non-default networks, named or anonymous
volumes, signal reload, adoption, provider-specific Compose arguments,
`longRunning = false`, unmatched secret targets, or removal policies other than
`delete` fail the bundle build. There is no silent Compose fallback.

## Validation Boundary

Compiler tests cover multi-file merge, nested/lazy/value-only interpolation,
literal dollars, `.env` syntax, unresolved environment entries, strict
rejection, local-image path validation, native remote/local image units,
health/restart mapping, dependencies, and network rendering. Every fleet bundle
runs through Podman's pinned generator, and the generated units are verified
together with the Nix public graph by `systemd-analyze --user verify`.

Lifecycle VMs prove generated-unit removal, partial-start graph unwinding,
non-mutating runtime verification, and a complete Compose-to-Quadlet-to-Compose
transition without native runtime state. The compiler check also evaluates with
`allow-import-from-derivation = false`. Compose restart identities content-hash
evaluator-visible files and use immutable store-path identities for generated
store files, so trusted-CA and secret restart detection never realizes a
derivation during evaluation. Generated-file assertions in the module test run
inside its derivation rather than importing outputs back into Nix evaluation.
All exported packages, checks, and host configurations evaluate with IFD
disabled. Fleet graph and host-closure builds are code-level evidence only; live
rollout and post-switch observation still require separate human approval.

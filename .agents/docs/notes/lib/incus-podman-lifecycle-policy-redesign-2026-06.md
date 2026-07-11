# Incus and Podman Lifecycle Policy Redesign (2026-06)

## Scope

Implementation plan for making Incus and Podman lifecycle behavior explicit and
safe during deploys. The immediate driver was a parent-host deploy of `pvl-x2`
that refreshed existing Incus guests even though the child host targets were
marked with `deploy = "skip"`.

This is a design note until the code lands. When implementing, update the
current platform notes and examples so they describe the final implemented
surface, not this transitional plan.

## Revalidated design summary

The final target model is:

| Surface          | Option                                                                                | Meaning                                                                                                           |
| ---------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Incus and Podman | `state` enum `running` or `stopped`                                                   | Desired runtime state. Default `running`.                                                                         |
| Incus            | `reconcilePolicy` enum `auto`, `declarative`, or `ignore`                             | Per-instance permission boundary for automatic reconciler mutation.                                               |
| Incus            | `reconcileFailurePolicy` enum `best-effort` or `strict`                               | Batch failure behavior. This replaces the current overloaded failure use of `reconcilePolicy`.                    |
| Incus            | `removalPolicy` enum `keep`, `stop`, `delete`, or `delete-all`                        | Removed-instance behavior; `keep` strips module ownership metadata for manual takeover.                           |
| Podman           | stack `reconcilePolicy`; instance `reconcilePolicy` with `inherit` plus action values | Drift action mode. Provider-specific semantics, not the same as Incus.                                            |
| Podman           | stack `removalPolicy`; instance `removalPolicy` with `inherit` plus action values     | Removed-instance behavior; default `delete`, with `keep`, `stop`, `delete`, and `delete-all` modes.               |
| Podman           | instance `adopt` boolean                                                              | Explicit permission to claim an existing unmanaged compose working directory.                                     |
| Podman           | remove `recreateOnSwitch`                                                             | Replace the blunt switch-time recreate knob with automatic recreate intent derived from recreate-relevant inputs. |
| Podman           | reload-aware recreate drift                                                           | `reloadStamp` reloads, restart-only drift restarts, and `recreateStamp` force-recreates.                          |

Design intent:

- Existing Incus guests can stay declared in the repo without automatic
  stop/recreate during a parent-host switch unless their policy allows it.
- Explicit declarative lifecycle tags remain useful. `bootTag` and `recreateTag`
  are treated as operator intent for the first three Incus policies except
  `ignore`.
- `ignore` means the declarative reconciler does not create, recreate, stop, or
  drift-reconcile that instance. Tags and `state` have no reconciler meaning
  under `ignore`. `autoStart` is separate: when enabled, the systemd unit may
  still start an existing guest at boot or target startup through the narrow
  start-only path.
- Podman gets the same public desired-state concept as Incus, but its reconcile
  surface remains the user-manager compose lifecycle rather than the Incus
  machine helper.
- Podman also gets a provider-specific `reconcilePolicy`, but it means "how far
  may automatic drift handling go" rather than Incus's "may this durable guest
  be mutated by the reconciler" boundary.
- Podman recreate-on-drift should be smarter than the old `recreateOnSwitch`.
  Reloadable config still reloads; container-shape drift recreates.

## Current behavior to change

Today these similarly named knobs have different responsibilities:

| Current option                                                        | Current meaning                                                 | Problem                                                                                    |
| --------------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Incus `global.autoReconcile`                                          | Enables the global `incus-machines-reconciler.service`.         | Does not protect per-instance `incus-<name>.service` units from running during activation. |
| Incus `global.reconcilePolicy` enum `off`, `best-effort`, or `strict` | Controls global reconciler scheduling/failure behavior.         | Name conflicts with the desired per-instance lifecycle policy.                             |
| Incus `bootTag`                                                       | Triggers restart.                                               | Correct primitive, but currently not policy-scoped.                                        |
| Incus `recreateTag`                                                   | Triggers recreate.                                              | Correct primitive, but currently not policy-scoped.                                        |
| Incus `imageTag`                                                      | Refreshes/imports image.                                        | Must stay non-recreating by itself.                                                        |
| Podman `bootTag`                                                      | Restarts the managed user unit.                                 | Keep.                                                                                      |
| Podman `reloadTag`                                                    | Reloads native-reload-capable instances.                        | Keep.                                                                                      |
| Podman `recreateTag`                                                  | Forces `podman compose up --force-recreate` once for a new tag. | Keep.                                                                                      |
| Podman `imageTag`                                                     | Enables the auxiliary image-pull unit.                          | Keep, then decide whether image changes also feed `recreateStamp`.                         |
| Podman `recreateOnSwitch`                                             | Always force-recreate on switch/start.                          | Remove; too broad and not reload-aware.                                                    |

Known code surfaces to inspect during implementation:

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/systemd-user-manager/default.nix`
- `hosts/abird-corp/services/stalwart/default.nix`
- `hosts/gap3-rivendell/services/stalwart/default.nix`
- `.agents/docs/design-patterns/podman-compose-instance.md`
- `.agents/docs/notes/hosts/incus-platform-consolidated-2026-04.md`
- `.agents/docs/notes/services/user-services-platform.md`
- `.agents/docs/notes/services/systemd-user-manager.md`

## Root cause to preserve

The unexpected Incus guest refresh did not come from nixbot selecting the child
hosts directly. `deploy = "skip"` only suppresses direct deploy target
selection.

The parent host still owned active per-instance units:

- `incus-<instance>.service` was `WantedBy=multi-user.target`.
- The unit had `restartTriggers` on rendered lifecycle state.
- The helper recreated when the stored config hash or `recreateTag` differed.
- `autoReconcile = false` only disabled the global
  `incus-machines-reconciler.service`; it did not disable the per-instance
  units.

The missing boundary is a first-class per-instance lifecycle policy. Deploy
selection, parent readiness, per-instance units, explicit lifecycle tags, and
helper drift handling must all consult the same policy.

## Design terminology

- Reconciler action: a mutation inferred from rendered declarative state, such
  as create, stop-for-desired-state, recreate-on-config-hash-drift, or restart
  on lifecycle tags.
- Auto-start action: the systemd unit start path controlled by `autoStart`. This
  is intentionally outside `reconcilePolicy`; for ignored Incus guests it may
  only start an existing instance and must not create, recreate, or
  drift-reconcile it.
- Declarative explicit action: a mutation explicitly encoded in declared state,
  such as `state = "stopped"`, `bootTag`, or `recreateTag`.
- Non-declarative explicit action: a direct operator command outside the normal
  declarative reconcile path, such as a helper override that intentionally acts
  on an ignored instance.
- Drift: a mismatch between rendered desired state and live/applied state.
- Recreate drift: drift that cannot be safely consumed by reload or restart
  alone because existing runtime shape may remain stale.

## Target Incus surface

Add per-instance desired state:

```nix
state = "running"; # "running" | "stopped"; default "running"
```

Add per-instance reconcile policy:

```nix
reconcilePolicy = "auto"; # "auto" | "declarative" | "ignore"
```

Rename the current global failure-mode option:

```nix
reconcileFailurePolicy = "best-effort"; # "best-effort" | "strict"
```

The current global `reconcilePolicy = "off" | "best-effort" | "strict"` is
overloaded. Its failure semantics should move to `reconcileFailurePolicy`.
Turning reconciler mutation off should be expressed through per-instance
`reconcilePolicy = "ignore"` or by not scheduling an automatic reconciler. This
does not disable boot or target startup; use `autoStart = false` for that.

## Incus policy matrix

| Policy        | Desired state | Missing instance         | Existing stopped instance | Config or kind drift                | `bootTag` | `recreateTag`              |
| ------------- | ------------- | ------------------------ | ------------------------- | ----------------------------------- | --------- | -------------------------- |
| `auto`        | `running`     | create and start         | start                     | recreate                            | restart   | recreate                   |
| `auto`        | `stopped`     | create and leave stopped | leave stopped             | recreate and leave stopped          | no start  | recreate and leave stopped |
| `declarative` | `running`     | create and start         | start                     | record/report pending recreate only | restart   | recreate                   |
| `declarative` | `stopped`     | create and leave stopped | leave stopped             | record/report pending recreate only | no start  | recreate and leave stopped |
| `ignore`      | either        | do nothing               | no reconciler action      | do nothing                          | ignored   | ignored                    |

`ignore` in this table is only the reconciler policy. It does not override
`autoStart`: an ignored guest with `autoStart = true` may still have its
`incus-<guest>.service` wanted at boot or target startup, but that path must
only start an existing guest.

`imageTag` remains image-import or image-refresh intent. It must not recreate an
Incus instance by itself. Pair it with `recreateTag` when an existing instance
should be recreated onto a refreshed image.

## Incus semantics

`state = "running"` means:

- `auto`: create if missing, start if stopped, restart on `bootTag`, recreate on
  `recreateTag`, and recreate on config/kind/hash drift.
- `declarative`: create if missing, start if stopped, restart on `bootTag`,
  recreate on `recreateTag`, and do not recreate merely because config hash
  drifted.
- `ignore`: no reconciler create/recreate/start/stop. `state`, lifecycle tags,
  image tags, and config drift have no reconciler meaning. `autoStart`, if true,
  may still start an existing guest through the narrow start-only unit path.

`state = "stopped"` means:

- `auto`: create if missing, apply allowed destructive reconcile, and leave
  stopped.
- `declarative`: create if missing and leave stopped; recreate only on
  `recreateTag`; stop if currently running.
- `ignore`: no reconciler action. `state = "stopped"` does not suppress
  `autoStart`; set `autoStart = false` when an ignored guest must not be started
  at boot or target startup.

Important edge rules:

- `bootTag` does not make a stopped instance running. A stopped desired state
  wins; a `bootTag` while stopped should be a no-op or a clearly reported
  skipped restart.
- `recreateTag` works for `auto` and `declarative` even when desired state is
  stopped; recreate the instance and leave it stopped.
- Type/kind drift under `declarative` must not silently recreate. Report pending
  recreate clearly and let `reconcileFailurePolicy` decide batch failure
  behavior where relevant.
- Do not write the desired config hash into the live applied hash when
  `declarative` skips recreate. That would erase the signal that a recreate is
  still pending.

## Incus implementation details

- Add `state` and per-instance `reconcilePolicy` to
  `services.incus-manager.<project>.instances.<name>`.
- Add a global default for the per-instance policy only if it keeps declarations
  readable; default to current behavior with `auto`.
- Rename the existing global failure knob to `reconcileFailurePolicy`.
- Include `state` and per-instance `reconcilePolicy` in the rendered machine
  runtime and lifecycle JSON.
- Make `mkMachineService` policy-aware:
  - `autoStart` controls whether the per-instance unit is wanted at boot or
    target startup, independently of `reconcilePolicy`.
  - `ignore` instances may keep that unit surface, but automatic or manual unit
    start must use a narrow start-existing-instance path rather than the full
    machine reconciler.
  - `auto` and `declarative` instances may use the full helper, which decides
    which reconciler mutations are allowed.
- Make the helper branch before destructive work:
  - `ignore`: return without reconciler mutation unless an explicit
    non-declarative override command is used. The separate start-only helper
    path may start an existing instance for `autoStart` or manual unit starts.
  - `declarative`: allow create, start, stop, `bootTag`, and `recreateTag`;
    detect config/kind drift but do not recreate from drift alone.
  - `auto`: preserve current drift-driven recreate behavior.
- Do not update the stored applied config hash when `declarative` skips a
  drift-driven recreate. Otherwise the pending recreate is hidden.
- For `state = "stopped"`, create or recreate when policy allows it, reconcile
  metadata/devices needed for a valid stopped instance, and leave it stopped.
- Make settlement state-aware:
  - `running`: wait for running status, guest reachability, IP, and SSH as
    today.
  - `stopped`: treat an existing stopped instance as settled.
  - `ignore`: observe only; do not mutate. Automatic deploy readiness should
    fail clearly if it requires an ignored instance to become ready.
- Keep declared `ignore` instances out of GC removal by virtue of being
  declared. If the declaration is removed, existing stored `removalPolicy` still
  controls GC.
- Filter ignored instances out of automatic image/import work so `imageTag` has
  no declarative effect under `ignore`.
- Add an explicit override path for operators that intentionally want to act on
  ignored instances, for example a helper or reconciler flag such as
  `--ignore-policy` or `--force-policy`.

## Incus reconciler and readiness behavior

Parent readiness and the global reconciler must use the same policy as the
per-instance unit:

- A selected `auto` or `declarative` instance with `state = "running"` may be
  created/started and settled.
- A selected `auto` or `declarative` instance with `state = "stopped"` may be
  created or stopped and then considered settled as stopped.
- A selected `ignore` instance must not be mutated by readiness or the global
  reconciler. If a child deploy requires that instance to be running and
  reachable, readiness should fail clearly instead of silently starting it.

The policy should be checked at every entrypoint, not only the batch reconciler:

- per-instance `incus-<name>.service`;
- `incus-machines-reconciler --all`;
- `incus-machines-reconciler --instance <name>`;
- parent readiness/settlement paths used by nixbot;
- image refresh/import paths;
- GC declaration filtering.

## Target Podman surface

Add per-instance desired state:

```nix
state = "running"; # "running" | "stopped"; default "running"
```

Add per-instance drift/action policy:

```nix
reconcilePolicy = "inherit"; # "inherit" | "auto" | "restart" | "recreate"
removalPolicy = "inherit"; # "inherit" | "keep" | "stop" | "delete" | "delete-all"
```

Add stack-level default drift/action policy:

```nix
services.podman-compose.<stack>.reconcilePolicy = "auto";
services.podman-compose.<stack>.removalPolicy = "delete";
```

Remove `recreateOnSwitch`.

Podman should also auto-force-recreate on relevant config drift, but the drift
must be reload-aware. Do not collapse every change into force-recreate.

## Podman parity decision

Podman should have `state = "running" | "stopped"` because operators need a
durable way to say "this compose instance belongs in the repo, but it should be
off now". `autoStart = false` is not the same thing; it suppresses automatic
start but does not communicate desired stopped state.

Podman should have a stack-level `reconcilePolicy` default and per-instance
`reconcilePolicy` enum values `inherit`, `auto`, `restart`, and `recreate`
because operators may want to set the normal drift policy once per stack and
override only exceptional instances. This is intentionally provider-specific. It
uses the same option name as Incus for discoverability, but it does not share
Incus's enum or exact semantics. Podman should not have
`reconcilePolicy =
"ignore"`; manual takeover belongs to `removalPolicy`.

Podman should expose stack-level
`removalPolicy = "keep" | "stop" | "delete" |
"delete-all"` with instance-level
`inherit` plus those values. `delete` is the default because it preserves the
old removal behavior: compose runtime shape and generated files are cleaned up.
`keep` leaves the old workload untouched for manual takeover and clears helper
ownership state, so a later re-declaration requires `adopt = true`. `stop` stops
compose containers without removing compose objects or generated files, and
keeps helper ownership state so the instance can be re-declared without
adoption. `delete-all` also asks compose to remove volumes and removes managed
staged dirs under the compose working directory. The generated unit still
disappears from the new system generation, so `keep` is a removal behavior, not
a steady-state unmanaged mode.

Podman should have instance-level `adopt = true` as a temporary, explicit
permission to claim an unmanaged working directory. The helper should refuse
non-empty unmanaged working directories unless adoption is set, then record
helper ownership state after a successful start.

Podman should auto-force-recreate on recreate-relevant config drift by default
because containers are comparatively cheap to recreate and many important
changes otherwise survive a plain restart or `compose up`. The implementation
must be reload-aware so services with meaningful native reload, such as nginx,
can still reload config instead of recreating containers for every file change.

## Podman lifecycle model

`state = "running"` means the instance participates in normal user-manager
start/reconcile behavior.

`state = "stopped"` is durable desired stopped state:

- stop the managed user unit if it is active;
- do not auto-start it on switch or boot;
- still render metadata and files so it can be resumed later;
- map to lower-level user-manager drain semantics, but expose `state` as the
  public option.

Keep `autoStart` as the lower-level "start at boot/switch" knob. Effective
behavior should be:

```nix
effectiveAutoStart = state == "running" && autoStart;
drain = state == "stopped" || migratorOn;
```

## Podman reconcile policy

Podman `reconcilePolicy` is a drift-action policy. `inherit` is a declaration
convenience only; generated metadata and helper state should use the resolved
effective policy.

| Policy     | Reload-class drift | Restart-class drift | Recreate-class drift | Tags              |
| ---------- | ------------------ | ------------------- | -------------------- | ----------------- |
| `inherit`  | from stack         | from stack          | from stack           | from stack        |
| `auto`     | reload             | restart             | force-recreate       | classified by tag |
| `restart`  | restart            | restart             | restart              | restart           |
| `recreate` | force-recreate     | force-recreate      | force-recreate       | force-recreate    |

Policy meanings:

- `inherit`: per-instance default. Resolve to
  `services.podman-compose.<stack>.reconcilePolicy`.
- `auto`: default smart policy. Use the module's classification: reload-class
  drift reloads, restart-class drift restarts, and recreate-class drift
  force-recreates.
- `restart`: blunt manual mode for exceptional services. Any declarative drift
  or lifecycle tag restarts the managed unit, including drift that `auto` would
  reload or force-recreate.
- `recreate`: blunt manual mode for exceptional services. Any declarative drift
  or lifecycle tag restarts the managed unit and the helper runs
  `podman compose up --force-recreate`.

Tags follow the selected policy. Under `auto`, `reloadTag`, `bootTag`, and
`recreateTag` keep their narrow action classes. Under `restart`, any changed tag
restarts. Under `recreate`, any changed tag force-recreates.

## Podman reload-aware recreate plan

Replace `recreateOnSwitch` with a dedicated recreate stamp.

| Drift source             | Desired action                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------ |
| `reloadStamp` drift      | `systemctl --user reload` or native signal reload when policy allows automatic reload                  |
| restart-only stamp drift | restart without forced recreate when policy allows automatic restart                                   |
| `recreateStamp` drift    | restart and run `podman compose up --force-recreate` when policy allows automatic recreate             |
| `reloadTag` drift        | reload                                                                                                 |
| `bootTag` drift          | restart                                                                                                |
| `recreateTag` drift      | force recreate once for the new tag                                                                    |
| `imageTag` drift         | pull/refresh image; include in recreate intent only if changed images should be consumed automatically |

Default design choice: include `imageTag` in recreate intent for Podman if the
goal is that changed images are consumed automatically on switch. This is an
intentional difference from Incus, where `imageTag` alone must not recreate an
existing instance. If preserving current Podman image semantics is preferred,
leave `imageTag` as pull-only and require `recreateTag` to consume the new
image. The implementation should make this choice explicitly in docs.

The helper should decide force-recreate from explicit tags plus the stored
recreate stamp:

```sh
should_force_recreate() {
  policy allows recreate && (recreateTag changed || recreateStamp changed)
}
```

The Nix module should compute separate stamps:

- `reloadStamp`: only reload-safe files and declared reload triggers.
- restart stamp: unit or runtime changes that need a restart but not a forced
  compose recreate.
- `recreateStamp`: compose files, entry files, container environment, env/file
  secret material, mounts, image refs, network/port/volume shape, and other
  inputs where existing containers may otherwise retain stale runtime shape.

This preserves meaningful reload behavior for services such as nginx while
making secrets, generated compose, image, and container-shape changes converge
without the blunt `recreateOnSwitch` hammer.

## Podman implementation details

- Add `state` to the instance option schema with default `running`.
- Add stack-level `reconcilePolicy` with default `auto`.
- Add per-instance `reconcilePolicy` with default `inherit`.
- Add stack-level `removalPolicy` with default `delete`.
- Add per-instance `removalPolicy` with default `inherit`.
- Add per-instance `adopt` with default `false`.
- Resolve effective policy during module rendering and put the effective value,
  not `inherit`, in generated metadata.
- Derive `effectiveAutoStart` from `state` and the existing `autoStart`.
- Map `state = "stopped"` to the user-manager drain path so active units are
  stopped and skipped during reconcile.
- Keep `autoStart` as a compatibility/lower-level knob for running services that
  should not start automatically.
- Add `recreateStamp` to generated metadata and helper state.
- Include `recreateStamp`, `recreateTag`, and `bootTag` in restart triggers for
  `auto` so the user-manager invokes the service when force-recreate intent
  changes.
- Keep `reloadStamp` and `reloadTag` in reload triggers only for
  native-reload-capable instances under `auto`.
- Compute an any-change stamp for `restart` and `recreate`; route all drift
  through restart triggers for those policies, and expose that stamp to the
  helper as the recreate stamp only for `recreate`.
- Gate helper force-recreate by `reconcilePolicy`, including explicit
  `recreateTag`.
- Replace `services.systemd-user-manager.stopOnRemoval` with `removalPolicy` and
  a provider removal command hook so Podman removal can distinguish `stop`,
  `delete`, and `delete-all`.
- Have provider removal commands own their own stop/wait semantics so Podman
  `keep` can clear helper ownership without stopping the workload.
- Remove `recreateOnSwitch` from defaults, option docs, generated metadata, and
  helper `should_force_recreate`.
- Update helper state recording so a successful force recreate records both the
  applied `recreateTag` and applied `recreateStamp`.

Suggested stamp split:

- `reloadStamp`: files listed in native reload triggers and other inputs that
  are known to be safe for signal reload.
- restart-only stamp: systemd unit metadata, helper wiring, timeout/stability
  metadata, reload method changes, and other inputs where restarting the unit is
  enough.
- `recreateStamp`: compose source, entry file, generated override files,
  compose-consumed `.env`, `envSecrets`, `fileSecrets`, trusted CA files mounted
  into containers, bind mount declarations, image refs, published ports,
  networks, volumes, pod/container shape, and any source/runtime file that
  changes container-visible environment or filesystem shape.

## Podman migration details

Known current `recreateOnSwitch` call sites:

- `hosts/abird-corp/services/stalwart/default.nix`
- `hosts/gap3-rivendell/services/stalwart/default.nix`

Migration direction:

- remove `recreateOnSwitch = true`;
- keep or adjust `recreateTag` where package or image changes should explicitly
  force recreate;
- rely on the new `recreateStamp` for generated config, env, secret, compose,
  mount, and container-shape drift.

The Stalwart call sites are the immediate correctness check because they are the
known users of the old broad recreate knob and are also services where secrets,
generated config, and package/image changes matter.

## Cross-cutting implementation order

1. Create a dedicated implementation worktree, for example
   `worktrees/lifecycle-policy-20260602`.
2. Implement Incus option schema and rendered JSON changes.
3. Rename or migrate Incus global failure policy.
4. Update Incus helper, per-instance units, reconciler, settlement, image, and
   GC paths to respect `state` and `reconcilePolicy`.
5. Implement Podman `state`, Podman `reconcilePolicy`, and user-manager
   drain/auto-start mapping.
6. Add Podman `recreateStamp` and remove helper metadata support for
   `recreateOnSwitch`.
7. Migrate Podman call sites.
8. Update current canonical docs and examples:
   - `.agents/docs/README.md`
   - `.agents/docs/design-patterns/podman-compose-instance.md`
   - `.agents/docs/notes/hosts/incus-platform-consolidated-2026-04.md`
   - `.agents/docs/notes/services/user-services-platform.md`
   - systemd-user-manager notes if the drain mapping changes
9. Port the Incus policy to `/home/pvl/src/nix` for parent-owned guests such as
   `gap3-gondor` and `abird-nest` after the current repo change is validated.

## Compatibility and migration choices

- Prefer preserving current default behavior for existing declarations: Incus
  defaults to `state = "running"` and `reconcilePolicy = "auto"`; Podman
  defaults to `state = "running"`, stack `reconcilePolicy = "auto"`, and stack
  `removalPolicy = "delete"`, with instance `reconcilePolicy` and
  `removalPolicy` both defaulting to `inherit`.
- If old Incus `global.reconcilePolicy` values are still accepted during a
  transition, emit clear deprecation warnings or assertions that point to
  `reconcileFailurePolicy`.
- If removing old Incus `global.reconcilePolicy` immediately, first confirm no
  repo host still sets it outside the option definition.
- `autoReconcile` may remain as a scheduler knob if needed, but it must no
  longer be presented as a lifecycle protection mechanism. The protection
  boundary is per-instance `reconcilePolicy`.
- `recreateOnSwitch` should be removed from public Podman declarations after
  migrating known call sites. If a temporary compatibility alias is kept, it
  should translate to recreate-stamp behavior only for one migration window and
  should be documented as deprecated.
- Podman `reconcilePolicy = "auto"` should preserve the intended default:
  classified reload/restart/recreate behavior. Use `restart` or `recreate` only
  when a service needs a blunt manual convergence mode.
- Podman instance `reconcilePolicy = "inherit"` should never reach runtime
  helpers. Helpers receive the effective policy after stack inheritance is
  resolved.

## Validation plan

- Format Markdown and Nix with repo-standard formatters.
- Run shell syntax checks for touched helper scripts.
- Evaluate affected option surfaces and generated metadata from the repo root
  without explicit `path:` flake refs.
- Build representative affected hosts with `--no-link`.
- Inspect generated Incus runtime/lifecycle JSON for policy and state fields.
- Inspect generated Podman metadata for `state`, effective `reconcilePolicy`,
  `removalPolicy`, `recreateStamp`, and absence of `recreateOnSwitch` and Podman
  `reconcilePolicy = "ignore"`.
- Confirm current Stalwart call sites no longer use `recreateOnSwitch`.
- Do not perform live persistent runtime mutation during validation without
  explicit user approval.

Representative hosts and surfaces:

- Incus parent/guest lifecycle: `gap3-gondor`, `abird-nest`, and the equivalent
  `pvl-x2` parent fabric when porting to `/home/pvl/src/nix`.
- Podman/Stalwart lifecycle: `gap3-rivendell`, `abird-corp`.
- Shared lower layer: `lib/systemd-user-manager/default.nix`.

## Acceptance criteria

- Existing Incus instances can be declared in the repo without implicit
  stop/recreate during a parent-host switch unless their policy allows it.
- `declarative` Incus instances still create, start, stop, and honor lifecycle
  tags, but do not recreate merely from config hash drift.
- `ignore` Incus instances are skipped by declarative reconciliation, image
  refresh, and lifecycle tags. They may still auto-start an existing guest when
  `autoStart = true`; use `autoStart = false` to suppress boot/target startup.
- Incus failure strictness is controlled by `reconcileFailurePolicy`, not by an
  overloaded lifecycle policy name.
- Podman instances have durable `state = "stopped"` without abusing
  `autoStart = false`.
- Podman instances can force blunt restart or recreate handling with
  `reconcilePolicy = "restart"` or `"recreate"`, or inherit the stack-level
  default with `reconcilePolicy = "inherit"`.
- Podman instances can set `removalPolicy = "keep"` to avoid stopping the old
  unit/workload when a declaration is removed, or `stop`/`delete-all` for
  explicit non-default removal behavior.
- Podman instances can set `adopt = true` temporarily to reclaim an unmanaged
  working directory, including one previously handed off with
  `removalPolicy = "keep"`.
- Podman helper state schema upgrades are not adoption events. If
  `.podman-compose/state.json` has the current adoption stamp but an older
  helper state version, the helper should migrate it before deciding whether the
  working directory is incompatible.
- Helper-owned `preStart` and `preStop` hooks run inside the compose helper, not
  as raw systemd overrides. Use them for staged-runtime-dependent bootstrap and
  pre-stop commands; keep `serviceOverrides` for true unit-level behavior.
- Under Podman `auto`, recreate-relevant drift and explicit `recreateTag`
  force-recreate while reload-safe drift still routes through reload. Under
  `restart` and `recreate`, any declarative drift uses the selected blunt mode.
- Podman has no `reconcilePolicy = "ignore"` mode.
- `recreateOnSwitch` is removed from the public Podman API and from known
  callsites.
- The start and restart-style reload paths repair stale inactive rootless
  network namespace resolver state before `podman compose up`, and force
  recreate when repair was needed so Podman does not reuse broken containers.

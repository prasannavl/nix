# systemd-user-manager Dispatcher/Reconciler Redesign (2026-03)

## Purpose

This note is the handoff-quality implementation plan for the next redesign of
`lib/systemd-user-manager.nix` and its `lib/podman.nix` integration.

It is intentionally detailed enough that another LLM or engineer can implement
the redesign without having to reconstruct:

- the failure history
- the rejected approaches
- the exact architecture decision
- the invariants we now care about
- the migration and verification plan

## Executive Summary

The current model still has the wrong ownership boundary:

- the system side performs too much direct mutation of user-managed state
- the system side still needs to know too much about user-unit reconciliation
- earlier versions used `systemctl --user --machine=<user>@` and
  `systemd-run --user --machine=<user>@`, which created a `systemd-stdio-bridge`
  and PAM/session storm under load
- the rewrite that tried to improve serialization also introduced a boot
  activation failure by using top-level `exit 0` in activation snippets

The new target design is:

- one **system-side dispatcher** service per managed user
- one **user-side reconciler** service per managed user manager
- the dispatcher only ensures the user manager is up, dispatches the user
  reconciler, and waits for convergence
- the user reconciler owns all actual reconciliation logic and all user-unit
  mutations

This redesign intentionally moves the system/user boundary earlier and makes the
system side much thinner.

## Why We Are Doing This

### Problem 1: Boot activation was broken by activation-script control flow

The regressing commit was `307016b`
(`Rewrite systemd-user-manager and podman
reconciliation`).

That commit added activation snippets which attempted to "skip on boot" with
top-level `exit 0`. Because `system.activationScripts` snippets are inlined into
the top-level `/activate` script, that `exit 0` aborted the entire activation
script.

This caused boot activation to stop partway through and directly explains the
observed "activation failed / switch-root got stuck" symptom.

That specific bug has already been fixed in the current tree by:

- removing top-level `exit 0` skip paths from activation snippets
- rewriting activation snippets as shell functions so they use `return`
  internally
- documenting the rule in `docs/ai/lang-patterns/nix.md`

But that only fixed the immediate control-flow bug. It did not address the
deeper architectural issue below.

### Problem 2: Root-side user-manager mutation caused bridge/PAM storms

The current and prior designs used root-side control of user managers through:

- `systemctl --user --machine=<user>@ ...`
- `systemd-run --user --machine=<user>@ ...`

This caused the system to create many `systemd-stdio-bridge` sessions for the
same user manager, especially on hosts like `pvl-x2` with many managed Podman
stacks and lifecycle actions.

Observed effects:

- many concurrent `systemd-stdio-bridge` units
- many PAM session opens for the same lingering user
- `pam_lastlog2 ... database is locked`
- `Failed at step PAM spawning systemd-stdio-bridge: Operation not permitted`
- `status=224/PAM`

Even when services sometimes converged, this transport was too fragile and too
expensive under concurrency.

### Problem 3: The system side still owns too much policy and mutation

The existing root-side reconciler script does all of the following:

- waits for user manager readiness
- reloads the user manager
- computes drift
- starts/restarts/stops managed user units
- launches lifecycle actions
- updates reconcile state
- reports convergence

That is the wrong split. The system side should not be the component that
understands or mutates detailed `systemd --user` state.

## Design Decision

Adopt a **dispatcher/reconciler split**:

- system side: one dispatcher per user
- user side: one reconciler service running inside that user's `systemd --user`

### System-side dispatcher

There is one system unit per managed user:

- proposed name: `systemd-user-manager-dispatcher-<user>.service`

Its job is strictly:

1. ensure `user@<uid>.service` is active
2. ensure the user manager sees the current user units
3. start or restart the user-side reconciler
4. wait for the user-side reconciler to finish
5. fail if the user-side reconciler fails

The dispatcher must not:

- inspect per-unit user state
- start/restart individual managed user services
- run lifecycle actions
- write desired-state manifests
- maintain per-managed-unit stamps

The dispatcher is an orchestrator only.

### User-side reconciler

There is one user unit per managed user manager:

- proposed preferred name: `systemd-user-manager-reconciler.service`

Because it runs inside a specific user manager, the username does not need to be
encoded in the unit name unless symmetry is desired.

The user-side reconciler owns:

- `systemctl --user daemon-reload`
- inspecting current unit state
- running pre-actions and post-actions
- starting/restarting/stopping managed units
- updating reconcile stamps/state
- starting `systemd-user-manager-ready.target` after successful convergence

This puts all detailed unit mutation where it belongs: inside the user manager
that actually owns those units.

## Explicit Design Choices Already Settled

### 1. Stateless handoff

We do **not** want a root-written desired-state manifest such as JSON under
`/var/lib/...`.

Reason:

- the generated user reconciler unit already embeds the declarative desired
  state in its own store path
- the user-side reconcile stamps are already the correct persistent state
- adding a second root-owned "desired state" handoff file is redundant and
  creates a second source of truth

Therefore:

- the dispatcher is stateless
- the reconciler derives desired state from its own generated script/store path
- the reconciler derives current state from live user-manager state plus its own
  persistent stamps

### 2. One dispatcher per user

We want one system dispatcher per user, not a single global dispatcher and not
per-unit bridge services.

Reason:

- user managers are per-user ownership boundaries
- failure and waiting should be isolated per user
- it keeps the system-side graph simple
- it preserves serialization at the user boundary

### 3. User-side reconciler owns all real work

The system side must only dispatch and wait.

Reason:

- that avoids the root-side bridge fanout problem
- it makes user-unit mutation local to the user manager
- it avoids root-side knowledge of all individual lifecycle actions and units

## Architecture Details

### Generated units

#### System units

For each managed user:

- `systemd-user-manager-dispatcher-<user>.service`

Expected ordering:

- `After=user@<uid>.service`
- `Wants=user@<uid>.service`
- likely `WantedBy=multi-user.target`
- conditioned on `/run/systemd/users/<uid>` or otherwise waits for user manager
  readiness

Responsibilities:

- user manager readiness wait
- trigger the user-side reconciler
- block until it converges or fails

#### User units

For each managed user manager:

- `systemd-user-manager-reconciler.service`
- `systemd-user-manager-ready.target`

The reconciler should be a normal user unit with stable naming and generated
content from Nix.

### Triggering model

The dispatcher should:

1. make sure the user manager exists and is reachable
2. do a user-side `daemon-reload`
3. start or restart `systemd-user-manager-reconciler.service`
4. wait for its final result

The transport should avoid `--machine=<user>@` fanout.

Two viable transports:

- direct user bus access using `XDG_RUNTIME_DIR=/run/user/<uid>` and
  `DBUS_SESSION_BUS_ADDRESS=unix:path=...` with `setpriv`
- a future single persistent bridge session if explicitly reintroduced

Current preference:

- direct user bus access

Reason:

- simpler
- no PAM churn
- no `systemd-stdio-bridge`
- closer to the real user manager API

### User-side reconcile state

Keep reconcile state where it logically belongs:

- per-user persistent reconcile state under the user reconciler's own state dir
- per-unit stamps remain the mechanism for drift/change detection

Do not add a second root-owned state layer.

### Lifecycle actions

Current model has lifecycle actions like:

- `imageTag`
- `recreateTag`
- `bootTag`

Under the redesign:

- these should be executed directly by the user reconciler
- they should not require root-launched transient actions
- if transient units are still desirable, they should be transient **user**
  units launched by the user reconciler itself

This means the user reconciler owns:

- whether an action runs
- in what order
- under what unit state conditions
- how state/stamps are updated after action completion

## Concrete Problems To Eliminate

The redesign must eliminate all of the following classes of bug:

### A. Activation-script termination bugs

Invariant:

- no activation snippet may use top-level `exit` for local control flow

Already fixed, but the redesign should further reduce activation complexity so
this class of bug is less likely to recur.

### B. Bridge/PAM storm from per-command `--machine=`

Invariant:

- no root-side reconcile fanout over `systemctl --user --machine=<user>@`
- no root-side transient action storm using
  `systemd-run --user --machine=<user>@`

### C. Root-side ownership of user mutation

Invariant:

- the system side should not start/restart/stop individual managed user units
- the system side should not execute per-unit lifecycle actions

### D. Service-start false negatives after workload success

Observed with Podman:

- `podman compose up` could succeed
- workload could actually be up
- wrapper/unit could still fail later because of wrong wrapper behavior

Invariant:

- user-side service result must correctly reflect actual intended convergence
- wrappers must not report failure after successful convergence due to malformed
  handoff logic

### E. Split brain between desired state and reconcile state

Invariant:

- desired state comes from the generated reconciler code/store path
- reconcile state comes from the reconciler's own persistent stamps
- do not introduce a third root-owned desired-state manifest

## Proposed Implementation Plan

### Phase 1: Introduce user-side reconciler generation

Refactor current generated root-side apply logic so the same core logic can be
emitted as a user-side executable and user unit.

Goals:

- generate a user-side reconcile script per managed user
- generate a user-side reconciler service to run it
- keep current semantics as close as possible

Important:

- the logic should use plain `systemctl --user`, not root mediation
- pre/post actions should execute in the user context

### Phase 2: Introduce thin system-side dispatcher

Generate one dispatcher service per user.

It should:

- ensure `user@<uid>.service`
- reload user units
- start/restart `systemd-user-manager-reconciler.service`
- wait for final result

At this phase, the dispatcher may still use direct user-bus access from root,
but only for:

- `daemon-reload`
- start/restart of the single reconciler unit
- observing reconciler unit result

There must be no per-managed-unit root-side mutations.

### Phase 3: Remove root-side unit/action reconciliation

Delete root-side reconcile responsibilities:

- per-unit start/restart logic
- root-side transient user actions
- root-side detailed user unit drift logic

The dispatcher should remain a launch-and-wait unit only.

### Phase 4: Re-home ready-target semantics

Ensure the user reconciler itself is the component that starts:

- `systemd-user-manager-ready.target`

This preserves current consumer semantics:

- managed user services that should auto-start after successful reconcile can
  still `WantedBy=systemd-user-manager-ready.target`

### Phase 5: Prune and identity handling review

Re-evaluate whether the current `Prune` and `Identity` activation snippets
should also move behind the dispatcher/reconciler split.

Likely direction:

- anything that mutates user-manager runtime state should move out of activation
  and into the dispatcher/reconciler model where possible

The goal is to shrink activation to the smallest safe surface.

## Detailed Open Questions

These are the main decisions the implementing model still needs to settle while
preserving the high-level architecture.

### 1. User unit naming

Current preference:

- system: `systemd-user-manager-dispatcher-<user>.service`
- user: `systemd-user-manager-reconciler.service`

Alternative:

- encode username in both names for symmetry

Tradeoff:

- username in user unit name is redundant but may simplify debugging if unit
  files are inspected from the system side

### 2. How dispatcher waits for convergence

Best current approach:

- query the user reconciler unit state over the user bus and wait until it is
  successful or failed

Avoid:

- per-action `systemd-run --wait` fanout
- writing custom progress manifests unless truly necessary

### 3. Whether lifecycle actions stay transient units or become direct execs

Two options:

- direct execution in the reconciler process
- transient **user** units launched by the user reconciler

Recommendation:

- start with direct execution unless systemd-level isolation is needed for a
  concrete action class

Reason:

- simpler
- fewer moving parts
- easier to debug

### 4. Where reconcile state lives

Likely best location:

- persistent per-user state dir owned by the user reconciler/service

Need to decide:

- system state dir with user-owned access
- user state dir under the user manager

Primary requirement:

- stamps must persist across boot and deploy
- ownership and access semantics must be unambiguous

## Migration Constraints

The redesign should preserve current intended semantics unless explicitly
changed.

That includes:

- inactive-but-startable managed units are intentionally started by reconcile
- `recreateTag` should force the next recreate/start path only
- normal start path must not use `--force-recreate`
- real Incus start failures must fail instead of being silently masked

The redesign is not permission to silently change service semantics.

## Postmortem Summary

The relevant incident history, in order:

1. The older bridge model created too many root-side bridge units and produced
   `systemd-stdio-bridge` / PAM storms under concurrency.
2. `307016b` rewrote the model toward one per-user reconciler, which was the
   right direction in spirit but still kept too much root-side mutation logic.
3. That same commit introduced a boot activation failure by using top-level
   `exit 0` in activation snippets.
4. The Podman service rewrite also introduced a malformed `systemd-notify`
   handoff bug in generated wrappers.
5. We fixed the activation control-flow bug.
6. We fixed the Podman wrapper bug.
7. We replaced the remaining root-side `--machine=` fanout with direct user-bus
   access as an intermediate mitigation.
8. The next proper step is this dispatcher/reconciler split so the system side
   stops owning detailed user-manager mutation entirely.

The main lesson:

- serialization alone was not enough
- the true issue was ownership and transport, not just concurrency

## Success Criteria

The redesign is complete only when all of the following are true:

- boot activation contains no mutable user-manager reconciliation logic that can
  abort `/activate`
- the system side has one dispatcher per user and no per-managed-unit bridge
  fanout
- the user side owns all actual reconcile logic and unit mutation
- the user manager no longer relies on `systemd-stdio-bridge` fanout for normal
  reconcile work
- deploy-time `switch` still reports convergence/failure clearly
- boot-time reconcile still happens automatically after userspace is available
- Podman stacks converge without false service failure after successful startup

## Recommended First Implementation Cut

If implementation needs to be staged, do it in this order:

1. Generate user-side reconciler unit/script per user.
2. Keep system-side dispatcher minimal and only responsible for triggering it.
3. Move pre/post actions into user-side execution.
4. Remove root-side per-unit/action reconciliation code.
5. Re-check prune/identity logic and move remaining runtime mutations out of
   activation where practical.

This yields the largest architectural improvement early while keeping rollback
and debugging manageable.

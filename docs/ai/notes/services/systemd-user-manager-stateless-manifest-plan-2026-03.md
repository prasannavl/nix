# systemd-user-manager Stateless Manifest Plan (2026-03)

## Outcome

The implementation ended up simpler than the manifest-plus-handoff plan below.

The current design is:

- no `/var/lib/systemd-user-manager`
- no root-owned mutable reconcile state
- one dispatcher system unit per user
- one reconciler user unit per user
- per-user immutable metadata rendered into the store and referenced from the
  generated dispatcher/reconciler units
- old-world stop performed by the old dispatcher unit’s `ExecStop` by comparing
  old metadata with the new dispatcher metadata already loaded into
  `/etc/systemd/system`
- new-world reconcile performed by the user reconciler using only new desired
  metadata plus live `systemctl --user` state

That means the `/run/nixos` transient handoff described below is no longer the
preferred direction. The rest of this note remains useful historical context for
why the durable state directory was removed.

## Purpose

This note is a handoff-quality implementation plan to remove
`/var/lib/systemd-user-manager/<user>/` entirely and replace the current mutable
per-user state model with an old/new generation manifest-diff model closer to
how NixOS `switch-to-configuration` handles system units.

It is intentionally detailed enough that another LLM or engineer can implement
the redesign without reconstructing the context from chat history.

## Problem Statement

The current `lib/systemd-user-manager.nix` design persists managed-unit state in
`/var/lib/systemd-user-manager/<user>/*.state`.

That state currently exists for three reasons:

1. old-world stop needs to know what the previous managed set was
2. new-world reconcile needs to know which managed units and actions changed
3. first-run versus subsequent-run behavior is derived from the presence or
   absence of prior state

This makes the module more stateful than desired and gives it a private mutable
database that NixOS native system-service switching does not require.

The goal is to remove that mutable state entirely and derive behavior from:

- the old generation
- the new generation
- the live active user-manager state
- minimal transient handoff files under `/run/nixos` only when absolutely needed
  during the switch transaction

## Current State Usage

### Mutable per-user state directory

Current path:

- `/var/lib/systemd-user-manager/<user>/*.state`

Current fields written into each state file include:

- `managed_unit_id`
- `managed_unit_user`
- `managed_unit_name`
- `managed_unit_unit`
- `stop_on_removal`
- `managed_unit_stamp`
- `managed_unit_lifecycle_stamp`
- per-action stamps

Current uses:

- detect changed managed units
- detect changed pre-actions and post-actions
- detect removed managed units
- decide first-run behavior
- decide old-world stop behavior

### Identity refresh state

Current path:

- `/run/nixos/systemd-user-manager/identity-<user>.stamp`

Current use:

- compare previous user/group identity stamp with the new one
- restart `user@<uid>.service` when identity changed

## Why We Want To Remove It

The user intent from the redesign discussion was:

- keep the old world and new world separate
- avoid carrying forward a private mutable state database
- make behavior derivable from immutable generation artifacts when possible
- follow NixOS native switch patterns instead of inventing a second long-lived
  source of truth

This specifically means:

- no durable semantic state under `/var/lib/systemd-user-manager`
- no need to "remember" previous managed-unit stamps in mutable files
- no root-owned desired-state cache

## How NixOS Native Switching Works

The local NixOS implementation to study is:

- `switch-to-configuration-ng`:
  `/nix/store/...-source/pkgs/by-name/sw/switch-to-configuration-ng/src/src/main.rs`

Relevant functions and behavior:

- `get_active_units()`:
  - asks live systemd over D-Bus which units are active right now
- `compare_units()`:
  - parses old unit files from `/etc/systemd/system`
  - parses new unit files from the new generation
  - decides whether a unit is equal, needs reload, or needs restart
- `handle_modified_unit()`:
  - derives stop/start/restart/reload behavior from:
    - old/new unit diff
    - live active set
    - unit metadata such as `X-StopIfChanged`, `X-RestartIfChanged`,
      `X-StopOnRemoval`, and `X-OnlyManualStart`
- transient work queues in `/run/nixos/*-list`:
  - `start-list`
  - `restart-list`
  - `reload-list`
  - activation-requested restart/reload lists

Important observation:

- NixOS does **not** maintain a private durable state database for system units
- it diffs old and new immutable generation artifacts and combines that with
  live unit state
- it uses `/run/nixos` only for transient switch-transaction coordination

## Key Architectural Difference From Native NixOS

For system units, NixOS has first-class old and new unit files for the exact
objects it is managing.

For `systemd-user-manager`, the managed objects are currently higher-level
logical entries:

- `services.systemdUserManager.instances.<name>`
- optional `observeUnit`
- optional `changeUnit`
- ordered pre-actions and post-actions
- `startOnFirstRun`
- `stopOnRemoval`
- semantic `restartTriggers`

These are not themselves old/new system-manager unit files.

So if we want stateless switching, we must first materialize these logical
managed objects into immutable old/new generation manifests that can be diffed
like NixOS diffs old/new unit files.

## Design Decision

Replace mutable per-user state files with immutable per-user manifests generated
into the system closure.

### High-level model

For each managed user, generate a manifest file in the system closure for that
generation.

During switch:

1. old-world stop phase compares:
   - old manifest from the currently running generation
   - new manifest from the target generation
2. new-world reconcile/start phase compares the same old/new manifests
3. live unit state is queried from the current user manager when needed
4. no durable mutable stamp files are written

### Allowed transient state

Transient coordination under `/run/nixos` is acceptable.

This matches NixOS native practice and is not considered durable semantic state.

Examples:

- handoff of old manifest store paths into the new-world phase
- crash-resilient "pending switch work" markers

### Disallowed durable state

The redesign target removes:

- `/var/lib/systemd-user-manager/<user>/*.state`
- `/run/nixos/systemd-user-manager/identity-<user>.stamp`

## Recommended Manifest Format

Use JSON plus `jq`.

Reasoning:

- structured nested action data is clearer in JSON than in ad hoc shell env
  files
- add/remove/rename of actions is easier to diff correctly
- JSON is stable to hash in Nix
- `jq` is already available in the repo and used elsewhere

### Manifest location

Recommended:

- old generation:
  - resolved to an absolute store path captured from `/run/current-system`
- new generation:
  - resolved from the target generation store path

Generated manifest path inside a generation:

- `<toplevel>/share/systemd-user-manager/<user>.json`

The exact subpath can vary, but it should be:

- immutable
- generation-local
- easy to derive from both old and new system closures

### Manifest schema

Recommended top-level shape:

```json
{
  "version": 1,
  "user": "pvl",
  "identityStamp": "<sha256>",
  "managedUnits": {
    "unit-pvl-nginx": {
      "id": "unit-pvl-nginx",
      "user": "pvl",
      "name": "pvl-nginx",
      "observeUnit": "pvl-nginx.service",
      "changeUnit": "pvl-nginx.service",
      "stopOnRemoval": true,
      "startOnFirstRun": true,
      "onChangeAction": "restart",
      "unitStamp": "<sha256>",
      "lifecycleStamp": "<sha256>",
      "preActions": {
        "imageTag": {
          "name": "imageTag",
          "stamp": "<sha256>",
          "execOnFirstRun": false,
          "observeUnitInactiveAction": "run-action",
          "timeoutSeconds": 300
        }
      },
      "postActions": {}
    }
  }
}
```

Notes:

- `unitStamp` is the semantic unit-only stamp
- `lifecycleStamp` is the full semantic stamp used to determine whether the
  managed entry changed in a way that should trigger old-world stop
- action metadata is present so the new-world reconciler can diff actions
  without mutable state
- `identityStamp` replaces the mutable identity stamp file

## Old/New Handoff Model

The new-world start phase cannot reliably discover the old manifest via
`/run/current-system` after switch finishes, because `/run/current-system` will
eventually point at the new generation.

So the old manifest path must be captured during activation and handed off to
the later start phase.

### Recommended transient handoff

Use per-user transient files under:

- `/run/nixos/systemd-user-manager/<user>.json` or
- `/run/nixos/systemd-user-manager/<user>.env`

Recommended contents:

- absolute old manifest store path
- absolute new manifest store path
- switch action

Example shell env file:

```sh
OLD_MANIFEST=/nix/store/...-systemd-user-manager/pvl.json
NEW_MANIFEST=/nix/store/...-systemd-user-manager/pvl.json
NIXOS_ACTION=switch
```

This is acceptable because it is:

- transient
- per-switch coordination state only
- equivalent in spirit to `/run/nixos/start-list` and related files

## Full Stateless Redesign

To truly remove `/var/lib/systemd-user-manager`, the redesign must change both
the activation stop phase and the reconciler.

### Part 1: Old-world stop phase

Activation should:

1. load old manifest
2. load new manifest
3. for each unit present only in old:
   - if `stopOnRemoval = true`, stop the old `changeUnit`
4. for each unit present in both:
   - if `lifecycleStamp` changed, stop the old `changeUnit`
5. if `identityStamp` changed, restart `user@<uid>.service` only after old-world
   stop completes
6. write the transient old/new manifest handoff file for the new-world phase

Important:

- this phase must not run `systemctl --user daemon-reload`
- this phase must stop units against the old live user manager
- this phase must run before identity refresh restarts `user@<uid>.service`

### Part 2: New-world reconcile/start phase

The reconciler must stop reading prior mutable state files and instead compare:

- old manifest entry for this managed unit, if any
- new manifest entry for this managed unit
- live current unit state from `systemctl --user`

Derived states:

- old missing, new present:
  - first run
- old present, new present, `lifecycleStamp` equal:
  - unchanged
- old present, new present, `lifecycleStamp` changed:
  - changed
- old present, new missing:
  - removed
  - should already have been handled in old-world stop

For actions:

- compare old action stamp by action name with new action stamp by action name
- missing old action + `execOnFirstRun=true` means run on first appearance
- removed actions need no persistent cleanup because old-world stop already
  handled the unit boundary

### Part 3: Cleanup removal of mutable state

After the manifest-based redesign is complete:

- delete state-file writing from the reconciler
- delete `/var/lib/systemd-user-manager` tmpfiles rules
- delete old state-dir creation in dispatcher/reconciler
- delete state-file cleanup logic
- delete mutable identity stamp path under `/run/nixos/systemd-user-manager`

## Detailed Implementation Plan

### Step 1: Introduce generated manifests

Add a manifest generator in `lib/systemd-user-manager.nix` that emits one JSON
file per managed user into the system closure.

Manifest generation should reuse existing semantic stamp logic:

- `userIdentityStampFor`
- managed-unit unit stamp
- managed-unit lifecycle stamp
- per-action stamps

### Step 2: Thread manifest paths into generated units

The generated dispatcher and reconciler should know the new manifest path.

Do not make them depend on `/run/current-system` for the old manifest.

### Step 3: Replace activation old-world stop implementation

Remove old-world stop logic based on sourced `.state` files.

Replace it with:

- old manifest read from captured old generation path
- new manifest read from new generation path
- stop decisions derived by manifest diff

### Step 4: Replace identity stamp file

Activation should compare:

- old manifest `identityStamp`
- new manifest `identityStamp`

This replaces:

- `/run/nixos/systemd-user-manager/identity-<user>.stamp`

### Step 5: Replace reconciler previous-state logic

The reconciler should:

- load old manifest for its user
- load new manifest for its user
- derive unit/action changes from manifest diff
- query live user-manager state only for current active/inactive/failed state

It should no longer:

- read per-unit `.state` files
- write new `.state` files

### Step 6: Keep transient `/run/nixos` handoff only

Introduce a small transient handoff file under `/run/nixos/systemd-user-manager`
so the new-world phase can find the old manifest even after
`/run/current-system` moves to the new generation.

This file should be:

- written during activation
- consumed by the dispatcher/reconciler
- cleaned up after successful completion or overwritten on the next switch

### Step 7: Verification pass

Verify at least:

- `switch` with unchanged managed set
- `switch` with changed managed unit stamp
- `switch` with changed action stamp only
- `switch` removing a managed unit with `stopOnRemoval = true`
- `switch` removing a managed unit with `stopOnRemoval = false`
- first-run behavior for a newly introduced managed unit
- identity change requiring `user@<uid>.service` restart
- `dry-activate` preview
- boot behavior

## Expected Advantages

- removes durable mutable state from `/var/lib/systemd-user-manager`
- aligns the design more closely with NixOS native switching
- makes old/new behavior derived from immutable generation artifacts
- avoids long-lived drift between current reality and a private stamp database
- makes handoff semantics clearer: old manifest, new manifest, live unit state

## Expected Costs

- more explicit manifest-generation logic
- reconciler becomes a manifest-diff engine instead of a state-file diff engine
- old/new manifest handoff must be implemented carefully because
  `/run/current-system` moves during switch
- JSON parsing with `jq` becomes a dependency of the generated shell logic

## Rejected Alternatives

### 1. Keep `/var/lib/systemd-user-manager` and just shrink it

Rejected because it still leaves a durable private state database in place and
does not solve the root concern.

### 2. Query only live user-manager state and keep no old/new generation data

Rejected because removed managed entries and custom stop policies become hard or
impossible to reconstruct reliably.

### 3. Keep a root-written desired-state cache under `/var/lib`

Rejected because it creates a second durable source of truth instead of using
the old and new immutable generations.

## Decision Summary

The recommended implementation is:

- no durable `/var/lib/systemd-user-manager`
- no mutable identity stamp file
- immutable per-user manifests in each generation
- old/new manifest diff for both stop and start logic
- transient `/run/nixos/systemd-user-manager/*` handoff only where needed

This is the closest analogue to how NixOS itself decides old-world stop versus
new-world start for system services.

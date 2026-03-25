# Incus Nested Reconcile And Deploy Readiness Plan (2026-03)

## Scope

Capture the current Incus nested-guest investigation, the confirmed root causes,
the fixes already made, and the next-step design for restoring reconcile in a
robust way without breaking guest activation.

## Problem statement

Two Incus guest regressions were observed after recent shared-module changes:

1. `gap3-gondor` sometimes completed deploy with the correct hostname, but its
   shell still exposed the bootstrap image PATH, so `incus` was missing.
2. `llmug-rivendell` lost Tailscale entirely even though its optional Tailscale
   secret still existed.

The original suspicion was a single hostname/bootstrap issue. Investigation
showed these were separate regressions.

## Confirmed findings

### 1. `llmug-rivendell` Tailscale loss was a shared-module config regression

- The reusable base profile `lib/profiles/systemd-container.nix` used to enable
  Tailscale unconditionally.
- That unconditional enablement was removed intentionally so optional guest
  Tailscale would live entirely in `lib/incus-vm.nix`.
- The optional Tailscale block in `lib/incus-vm.nix` wired:
  - `authKeyFile`
  - `authKeyParameters`
  - `extraUpFlags` but did **not** set `services.tailscale.enable = true`.
- Result: guests with a Tailscale secret evaluated with Tailscale config but no
  Tailscale service.

This is a real regression and was fixed in `lib/incus-vm.nix` by making the
optional block also enable `services.tailscale`.

### 2. `gap3-gondor` missing `incus` was not a package regression

Evaluation showed `gap3-gondor` still had Incus in its intended real config. The
live problem was a split runtime state:

- `/nix/var/nix/profiles/system` pointed at the real `gap3-gondor` closure
- `/sbin/init` pointed at the real `gap3-gondor` closure
- `/run/current-system` still pointed at the bootstrap `nixos` closure

Because shell PATH ends in `/run/current-system/sw/bin`, `incus` looked absent
even though it existed under the real system profile.

Manual proof:

- relinking `/run/current-system` to the real system profile immediately made
  `incus` appear again in `gap3-gondor`
- therefore the problem was stale runtime generation exposure, not package
  composition

### 3. The stale `/run/current-system` was a side effect of activation-time

reconcile, not the hostname unit

The hostname work was investigated separately:

- direct writes to `/proc/sys/kernel/hostname` were unreliable in Incus guests
- `hostname(1)` succeeded reliably
- the final hostname fix stayed in `lib/incus-vm.nix` as a dedicated systemd
  oneshot using `hostname(1)`

However, that was not why `gap3-gondor` lost `incus`.

The actual differentiator was that `gap3-gondor` is itself an Incus host. A
recent change added activation-time guest reconcile to `lib/incus.nix`:

- commit `7e7f530` added `system.activationScripts.incusMachinesReconcile`
- commit `7c2611b` added policy modes `off|best-effort|strict`

During `gap3-gondor`'s own first guest-side `switch`, that activation script
also reconciled and started its child guest `gap3-rivendell`.

This meant `gap3-gondor` was doing nested Incus lifecycle work in the middle of
its own host activation.

Important observation:

- `switch-to-configuration` still returned success
- `gap3-rivendell` was in fact created and started successfully
- no explicit failure was logged because the reconcile action itself succeeded
- the broken state was a host activation side effect: `gap3-gondor` finished in
  a partially converged runtime state, with `/run/current-system` still pinned
  to bootstrap

So this was not "reconcile failed". It was "reconcile ran at the wrong time and
interfered with host activation convergence."

### 4. Why `pvl-x2` behaved differently

`pvl-x2` is a stable parent host, not a guest in the middle of a bootstrap to
real-config transition.

That distinction matters:

- `pvl-x2` can tolerate activation-time reconcile better because it is already a
  real host doing ordinary host activation
- `gap3-gondor` was still switching from the reusable Incus base image to its
  real host closure while also acting as an Incus parent

So the same reconcile implementation was not equivalent on the two systems.

## Fixes already made

### Shared module fixes kept

- `lib/incus-vm.nix`
  - optional Tailscale block now enables `services.tailscale`
  - runtime hostname convergence uses `hostname(1)` in a dedicated oneshot
  - reboot fallback was removed

### Temporary policy fix kept

- `lib/incus.nix`
  - activation-time reconcile now defaults to:
    - `best-effort` on non-container hosts
    - `off` on containerized Incus hosts

This is the current safe behavior because it prevents nested Incus hosts from
reconciling child guests during their own activation.

### Recovery-only idea rejected

A short-lived recovery idea added a service to force `/run/current-system` to
follow `/nix/var/nix/profiles/system`.

That was removed because it was a band-aid over the stale-state symptom, not the
root cause.

## Design direction under discussion

The desired end state is to keep reconcile, but move it out of
`system.activationScripts` and into a real post-switch orchestration phase.

### Why not keep it at the end of activation?

Even the "very end" of `system.activationScripts` is still before NixOS's final
runtime commit step that updates `/run/current-system`.

So moving the work to the tail of activation is better than doing it earlier,
but still not a true post-commit model.

### Robust direction

Split the problem into two concerns:

1. **Host deploy/activation**
   - converge the host itself
2. **Incus guest reconcile/readiness**
   - create/start/reconcile child guests only after the host is settled

## Proposed plan

### Phase 1: Move reconcile out of activation

Replace `system.activationScripts.incusMachinesReconcile` in `lib/incus.nix`
with a dedicated oneshot, for example:

- `incus-machines-reconcile.service`

That unit should:

- inspect declared guests
- create/start/reconcile missing or stopped guests
- preserve policy modes:
  - `off`
  - `best-effort`
  - `strict`

It should not run inside activation script control flow.

### Phase 2: Add an explicit readiness barrier

Add a second concept distinct from "reconcile dispatched":

- `incus-machines-settle`
- or an exported host-side helper script

This is not primarily a mutator. It answers:

- are the relevant declared guests now present?
- are they running?
- are they reachable enough for the next deploy step?

Suggested readiness checks for a given child:

- guest exists in Incus
- guest state is `Running`
- `incus exec` works or expected IP is present
- SSH to the target works as `nixbot`

That last point matters because SSH reachability is what later `nixbot`
snapshot/deploy waves actually need.

### Phase 3: Teach `nixbot` to gate on readiness, not just ordering

Current `hosts/nixbot.nix` edges such as:

- `gap3-gondor.after = ["pvl-x2"]`
- `gap3-rivendell.after = ["gap3-gondor"]`

only mean "deploy parent first." They do not mean "parent has finished
reconciling the dependent child and the child is reachable."

The orchestration model should become:

1. deploy parent host
2. if selected downstream targets depend on that parent via Incus:
   - trigger the parent-side reconcile unit
   - wait on parent-side settle/readiness for the relevant child names
3. only then run snapshot/deploy for the dependent guest wave

This makes dependency edges mean:

- ordering **plus**
- dependency readiness

### Phase 4: Scope waiting to selected targets

If only the parent host is selected, `nixbot` should not block on all Incus
guests settling.

If a selected target depends on that parent, `nixbot` should only wait for the
specific dependent guest(s) relevant to the selected graph.

Examples:

- selecting `pvl-x2` only:
  - deploy parent
  - no child-readiness barrier required
- selecting `gap3-gondor`:
  - deploy `pvl-x2`
  - reconcile/settle `gap3-gondor`
  - then snapshot/deploy `gap3-gondor`
- selecting `gap3-rivendell`:
  - deploy `pvl-x2`
  - reconcile/settle `gap3-gondor`
  - deploy `gap3-gondor`
  - reconcile/settle `gap3-rivendell`
  - then snapshot/deploy `gap3-rivendell`

## Pros of the proposed direction

- keeps automatic reconcile behavior
- removes heavy nested guest lifecycle work from activation
- avoids stale host runtime state caused by mutation during host switch
- makes parent deploy success separate from child readiness
- gives `nixbot` a real dependency barrier instead of relying on ordering alone
- works for nested Incus parents without reboot-based hacks

## Cons / complexity

- requires more explicit `nixbot` orchestration
- introduces two concepts instead of one:
  - reconcile
  - settle/readiness
- logging is split across:
  - parent deploy
  - reconcile unit
  - readiness wait
- best-effort parent behavior and strict child gating must be designed carefully
  so failures are reported clearly

## Current repo state when this note was written

- `lib/incus-vm.nix`
  - hostname oneshot retained
  - Tailscale enablement fixed
- `lib/incus.nix`
  - containerized Incus hosts default `reconcileOnActivation = "off"`
  - non-container hosts default `best-effort`
- docs updated to reflect the current safe state

This is the correct short-term safety posture, but not the desired final
architecture.

## Recommended next session starting point

1. Design `incus-machines-reconcile.service` and a settle/readiness interface in
   `lib/incus.nix`.
2. Decide whether readiness is implemented as:
   - a systemd oneshot
   - a plain exported script
   - or both
3. Update `nixbot` orchestration to:
   - trigger reconcile only when selected downstream Incus-dependent hosts need
     it
   - wait for readiness before snapshot/deploy of dependent waves
4. Remove activation-time reconcile entirely once the new flow is in place.

# pvl-x2 Incus Capacity and Admission, 2026-07

## Incident

Deploy `u9AZjQ` never authenticated to its first target. The physical Incus host
`pvl-x2` had rebooted shortly before the run and was intermittently unreachable.
The previous boot ended after global OOM pressure, journald watchdog failure,
and a hardware-watchdog reset. The current boot repeated a global OOM that
killed the Abird Penpot backend.

This was not a nixbot activation or application-specific regression. All Incus
guests started concurrently after the parent reboot, and each Corp guest then
started its large rootless Podman graph. The shared Btrfs-backed `dm-0` path
entered a 20-25 minute cold-page-in and overlay-read storm while the unused
second NVMe remained idle.

Representative exact cgroup memory during the incident:

- `gap3-gondor`: 31.19 GiB, including nested Abird Corp at 16.22 GiB and the
  unrelated `gap3-rivendell` guest at 9.71 GiB;
- `abird/abird-corp`: 10.98 GiB current, 14.19 GiB peak;
- `abird-dev/abird-corp`: 8.00 GiB current, 15.81 GiB peak;
- no swap at any layer.

Even after D-state tasks and short-term pressure subsided, the 62 GiB host had
only about 4.6 GiB available. This baseline cannot safely absorb simultaneous
full-stack recovery.

## Ownership model

Cold-start admission and deploy admission are separate boundaries:

- nixbot's optional `deployJobsPerDomain` limits concurrent mutations within
  each topmost-parent tree; when unset, it follows the global deploy-job limit
  and adds no narrower per-domain override;
- `services.incus-manager.global.startConcurrency` limits automatic Incus guest
  starts owned by one controller;
- per-instance and per-project Incus resource budgets must contain steady-state
  memory and I/O consumption;
- the physical `pvl-x2` configuration in this repository owns outer-controller
  budgets, swap, and storage placement. Child repositories cannot guarantee
  parent safety alone.

Do not solve this class by raising SSH `MaxStartups`, extending transport
timeouts, or globally serializing every guest. Those changes do not bound the
physical failure domain. A dense role may still use its existing
start-through-ready admission window when live evidence shows its default is too
wide; that is a workload policy, not a substitute for parent capacity.

## Automatic-start waves

The Incus manager supports optional bounded automatic-start waves. Eligible
instances are sorted by ascending `startPriority`, then stable declaration key,
and admitted in groups of at most `startConcurrency`.

Each wave has explicit systemd ordering:

```text
gate -> instance lifecycle units -> readiness settlement -> next gate
```

Settlement reuses `incus-machines-settlement`, so the next wave begins only
after the current guests reach Incus running state, accept exec, report their
declared address, and expose SSH when configured. Dependencies are weak `Wants`
plus ordering, not `Requires`: one failed guest remains failed in its own unit,
the bounded settlement reports it, and later waves still proceed.

Scheduling metadata is excluded from instance config hashes and lifecycle state.
Enabling or reprioritizing waves must not recreate guests. Direct manual starts
also remain available through each `incus-<instance>.service`.

The physical `pvl-x2` controller starts at most two guests per automatic-start
wave. The production-bearing `abird-nest` and `gap3-gondor` controllers form the
first priority tier; `pvl-vlab` and `pvl-vlab-1` form the later tier.

The nested Abird controllers also start two guests per automatic-start wave.
Nixbot leaves `deployJobsPerDomain` at its default so its global deploy-job
limit remains the only deploy admission ceiling:

- active production identity and data first;
- ingress and observability next;
- ordinary production roles next;
- Corp last within each stack;
- `abird` before `abird-dev`, and inactive stage declarations last;
- unrelated Gondor Rivendell guests after the Abird Gondor stack.

## Deploy evidence after admission

Deploy `Y3o59C` proved the then-configured controller and two-wide nixbot waves
on `abird-gondor`: the parent ran alone, guests ran in pairs, and Corp ran
alone. All ten hosts and health checks passed in 3m25s without a transport
storm.

Deploy `HncSYy` then proved that the same host-level isolation was insufficient
inside the dense `abird-corp` guest. Corp inherited the Podman graph default of
four start-through-ready lanes; four unrelated projects were verifying at once
when `pvl-x2` reached load 1305, 251 D-state tasks, memory PSI 89%, and I/O PSI
99%. The shared Corp role temporarily set `startConcurrency = 1` for the next
diagnostic deploy. That backend-neutral policy applied to Gondor, active Abird,
dev, and stage, admitting one Compose or Quadlet main/reconcile/verify/ready
graph at a time.

Retry `kSpd7N` proved the one-lane graph. Corp progressed through exactly one
verifier at a time, but the physical host still collapsed later as the admitted
services accumulated. With active Gondor and dev Corp replicas already resident,
active Abird Corp grew to about 10.7 GiB and left only 2.6-3.8 GiB available on
a host with no swap. Global reclaim then drove load above 1100, 278 D-state
tasks, memory PSI above 80%, and I/O PSI above 99%. Stopping only active Abird
Corp immediately restored about 12-13 GiB available and near-zero pressure. This
establishes total resident capacity as the remaining blocker; neither deploy
fan-out nor per-guest start fan-out is the cause. Corp therefore returns to four
start-through-ready lanes: serializing its graph slows recovery without
containing the accumulated resident set that exhausted the physical host.

## Remaining physical capacity work

Boot and service admission remove synchronized recovery storms but do not create
RAM. Before treating all full Corp replicas as safely co-resident, the physical
`pvl-x2` must provide reclaim headroom such as host-owned swap and declare hard
absolute memory budgets whose sum leaves host/Incus/cache reserve. It should
also isolate high-read dev or stage storage onto the unused NVMe. Incus project
memory limits require corresponding absolute instance memory limits. Resource
limits must be reconciled live rather than folded into the current recreate
hash.

Reference:
[Incus project limits](https://linuxcontainers.org/incus/docs/main/reference/projects/)
and
[Incus instance options](https://linuxcontainers.org/incus/docs/main/reference/instance_options/).

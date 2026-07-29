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
- per-instance and per-project Incus limits must contain steady-state memory and
  I/O consumption;
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

## Limit envelopes

Boot and service admission remove synchronized recovery storms but do not create
RAM. Incus limits therefore have two ownership layers:

- the physical controller caps the `abird-dev` project at seven containers,
  eight CPUs, 8 GiB memory, and 512 GiB storage;
- the seven Abird-dev guests sum to eight CPUs and 7.5 GiB memory, leaving
  project-level controller margin, with per-role network and disk-I/O limits;
- the physical controller caps outer `gap3-gondor` at 22 CPUs, 50 GiB memory,
  and 600 Mbit/s;
- the eleven nested Gondor guests sum to 20 CPUs and 46 GiB memory, leaving two
  CPUs and 4 GiB for the nested controller. Corp keeps a 24 GiB ceiling and
  `gap3-rivendell` keeps 11.25 GiB, both above the observed resident set.

The stack-facing instance API groups device limits under
`limits.disk.devices.<name>` and `limits.network.devices.<name>`. Disk `read`
and `write` are directional, while `rw` applies one combined value; network `rx`
and `tx` are from the instance perspective, while `rxtx` applies one combined
value. The renderer maps `rw` and `rxtx` to Incus device `limits.max`. Combined
and directional forms are mutually exclusive for the same device.

Priority-like settings retain their native domains instead of inventing a
cross-subsystem scale. Explicit CPU and disk priorities use Incus `0` through
`10`; null leaves Incus's effective defaults of CPU `10` and disk `5`.
`limits.memory.oomScoreAdjustment` uses the kernel `-1000` through `1000`
domain; null leaves the effective neutral value `0`. Network priority is not
part of the public API because Incus only applies it for specific queued NIC
types. Unset options remain unmanaged, so existing manual values are not claimed
or removed.

Container swap policy is typed as `limits.memory.swap.enable` plus optional
`limits.memory.swap.max`. The default `{ enable = true; max = null; }` emits no
Incus key and inherits native swap behavior. Disabling emits `false`; an enabled
non-null maximum emits that size. A disabled policy cannot also declare a
maximum, and virtual machines cannot override either swap field.

The shared Incus module keeps limit state outside the recreate hash. A dedicated
oneshot reconciles only the declared config and device limit keys on an existing
owned guest, and the normal lifecycle path applies the same limits when creating
or adopting one. Removing a declared limit unsets only keys previously recorded
as module-owned.

All pools remain on their existing physical storage by explicit policy; this
change does not use or migrate to the unused NVMe. The deployed Incus 7.2
servers do not advertise the `disk_io_limits_combined` API extension, so each
disk direction accepts one byte/s or one IOPS value and the current declarations
choose byte/s. A combined comma-separated value can be enabled after the fleet
is upgraded to a server that advertises that extension.

Nested `gap3-gondor` guests intentionally omit disk-I/O limits. Their Incus
`dir` pool sits on a Btrfs mount passed down from `pvl-x2`; inside the nested
host, `findmnt` exposes the parent LUKS mapper path but the corresponding block
device is not present. Incus therefore rejects the guest start with
`Invalid
block device` when a disk limit is declared. The host sets
`diskIoLimitsSupported = false`, so a future nested disk-limit declaration fails
at Nix evaluation rather than during deployment.

Direct `pvl-x2` Incus declarations can still carry disk-I/O limits because the
host can resolve the backing device, including the outer `gap3-gondor` limit.
However, the current Btrfs-over-device-mapper path can prevent the kernel
block-I/O controller from enforcing them. Validate effective throttling under
load instead of treating declaration as proof. True hard disk isolation still
requires a separate physical device or host.

Host-owned swap remains future reclaim work. The memory ceilings are hard
absolute limits and their sums deliberately leave host and controller reserve.

Reference:
[Incus project limits](https://linuxcontainers.org/incus/docs/main/reference/projects/)
and
[Incus instance options](https://linuxcontainers.org/incus/docs/main/reference/instance_options/),
[disk devices](https://linuxcontainers.org/incus/docs/main/reference/devices_disk/),
and
[storage-volume I/O limits](https://linuxcontainers.org/incus/docs/main/howto/storage_volumes/).

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

### Build-triggered reclaim storm, 2026-08-31

An abandoned remote build remained owned by the Gondor CI Nix daemon after the
client lost SSH. It concurrently compiled Stalwart with Rust and Node.js/V8 with
17 C++ compiler workers. About one hour later, the CI cgroup still held 23.8
GiB: one `rustc` process held about 5.6 GiB RSS and individual `cc1plus`
processes held 0.35-1.9 GiB each. CI had not crossed its 32 GiB limit or
recorded an OOM.

The complete nested stack did cross the relevant capacity boundary. The outer
`gap3-gondor` cgroup was pinned at its exact 50 GiB hard limit, the physical
host had only 1.4 GiB available, anonymous memory occupied about 54 GiB, the
file cache had fallen to about 3.2 GiB, and no swap existed. The resulting
direct reclaim continually evicted pages from every nested guest and made them
cold-read their executables, databases, and rootless container layers again.

Physical-device samples showed about 1.1 GiB/s reads and essentially no writes
through `nvme0n1 -> LUKS dm-0 -> Btrfs`, with roughly 200 queued operations,
8-10 ms read latency, and 33-34% CPU I/O wait. The second NVMe remained idle.
The nested cgroup accounting simultaneously reported about 2.1 GiB/s logical
reads: CI led one sample at 298 MiB/s, but Corp, both Rivendell roles, proxy,
server, data, Zulip, and other guests were also faulting back hundreds of MiB/s.
At the same time, 393 processes were blocked in uninterruptible I/O: 155 in
Corp, 108 in `gap3-rivendell`, and 27 in CI. The blocked population included
Postgres, `fuse-overlayfs`, application runtimes, and the compiler workers.

Both `/build` and `/nix/store` inside nested CI resolve to the same physical
Btrfs filesystem through two directory-backed Incus layers. This incident is
therefore memory-induced page-cache thrashing on shared storage, not write
saturation, raw CPU over-admission, or an NVMe fault. Lowering build CPU count
alone does not establish a safe envelope: the build working set plus resident
services must fit below the outer 50 GiB limit with enough room left for useful
file cache. When a deploy client disconnects, first check for daemon-owned
builds before retrying because another client is not required for those builds
to keep consuming the shared memory and disk failure domain.

The operator approved cancellation after the work had run for about one hour. At
the 50 GiB hard limit, both nested SSH and `incus exec` lacked enough headroom
to fork the cancellation command. Recovery temporarily raised only the outer
`gap3-gondor` limit from 50 GiB to 51 GiB, wrote `1` to the nested
`abird-ci/system.slice/nix-daemon.service/cgroup.kill`, and restored 50 GiB
immediately through a shell trap. It did not restart the outer production
container or the CI instance.

The build cgroup emptied immediately. CI memory fell from 23.8 GiB to about 270
MiB, physical-host available memory rose to about 24 GiB, D-state processes fell
from 393 to 3, physical reads fell from about 1.1 GiB/s to 3-12 MiB/s, and I/O
wait returned near zero. Clearing the intentional failed marker left
`nix-daemon.service` inactive, `nix-daemon.socket` active, no failed CI units,
and no compiler processes. This is the bounded cancellation path when the memory
limit itself prevents ordinary nested control-plane access.

The pressure interval also left seven nested guests without their declared
DHCPv4 addresses. Incus still held every static lease and every veth remained
forwarding, but guest `systemd-networkd` logs showed netlink operations timing
out under pressure and later showed the affected links as IPv6-only or failed.
This removed `10.10.30.20` from the proxy, so the healthy CoreDNS listener was
unreachable and every `~abird.internal` query, including the CI cache name,
timed out. Reconfiguring only `eth0` with `networkctl reconfigure eth0` restored
the declared IPv4 address on proxy, Corp, dev, identity, Tic-Tac-Toe, Zulip, and
`gap3-rivendell`; no guest restart was required. The real nixbot bootstrap check
then passed through the parent for Corp, proxy, Zulip, and CI.

Network recovery alone does not make the cancelled deployment safe to retry. The
CI realization dry-run still listed the same 45 derivations, including the
Stalwart and Node.js/V8 image builds whose outputs remained absent. Prebuild
that closure in a failure domain with a safe memory/cache envelope before a
fresh fleet deployment; otherwise the retry recreates the initiating workload.

### Builder GC coordination and admission, 2026-09-01

The next deployment established why the workload became cold without a source
regression. The CI host's weekly GC deleted 49,142 unrooted paths (96.4 GiB),
including the exact Stalwart, OpenDesign, and Node.js outputs needed by Corp.
Nixbot's remote build used `--no-link`, Harmonia served only the live store, and
the builder had no durable root for a successfully built target closure. The
following deployment therefore rebuilt the full heavy graph. The later SSH
banner failures were consequences of the resulting shared reclaim storm, not its
cause.

Nixbot does not own builder cache retention or generation rotation. The builder
role instead serializes supported GC entrypoints against active consumers with
one fixed advisory lock. A fleet invocation holds a shared kernel lease while
the builder or its cache can still be needed; scheduled `nix-gc.service` and
host-agent maintenance GC take the exclusive side. There are no Nix profiles,
out-links, run directories, retained generations, cleanup RPCs, or reapers in
this protocol. Closing the lease SSH connection, killing either process, or
rebooting either machine releases the lock in the kernel, so crashes cannot
leave persistent retention state behind.

The lease transport is independent of ordinary build, target, and activation SSH
connections. If it is lost before a builder-dependent operation, the controller
reacquires it and re-realizes the planned derivation, requiring the same exact
output path before retrying. If the path survived, this is a cheap verification;
if GC collected it, Nix rebuilds it. Work already copied and verified on a
target remains valid, so a later lease loss does not retroactively fail the
deployment. The controller releases the lease once no later phase can read from
the builder; GC timing and age policy remain owned by NixOS.

This is a builder-role contract, not a global Nix setting. A new builder gets
the GC guard and conservative build admission by enabling the role. The
controller owns the generation-independent inline lease protocol, so no
generation-provided helper or separate bootstrap is required. Direct
administrator invocations that bypass both `nix-gc.service` and host-agent
maintenance are outside the supported coordination surface.

The `pvl-x2` builder role also admits one Nix derivation at a time. It leaves
`cores = 0`, so the admitted derivation automatically receives the effective CPU
set. This is an admission lane, not a fabricated RAM formula: Nix derivations do
not declare reliable peak memory, and the relevant parent failure domain remains
independently overcommitted. Every additional builder role inherits the same
conservative lane and GC coordination contract. Global `lib/nix.nix`, ordinary
hosts, and the fleet GC policy remain unchanged.

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

The parent `abird-dev` project deliberately blocks low-level container config.
Its guests therefore leave `limits.memory.oomScoreAdjustment` null: Incus
classifies the rendered `limits.memory.oom_priority` key as low-level and
rejects instance creation when that project restriction is active. Do not weaken
`restricted.containers.lowlevel` for this optional tuning. The outer
`gap3-gondor` guest remains in the unrestricted default project and keeps its
declared `-250` adjustment.

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

The limits oneshot can run before lifecycle attachment when recovering a
partially created guest. If Incus reports that a declared device is not yet
available as a profile device, limit reconciliation defers that device; the
machine lifecycle attaches it and applies the same limits. Other override errors
remain fatal.

Project limit admission happens inside Incus before an instance exists. When a
project declares aggregate CPU or memory limits, `incus create` rejects a new
instance unless its per-instance `limits.cpu` and `limits.memory` are part of
the create request; setting them immediately afterward is too late. The shared
helper therefore passes every rendered config limit as a create-time `--config`
argument and still runs normal post-create reconciliation. The 2026-08-30 Nest
activation exposed this ordering bug while creating the seven declared
`abird-dev` replicas.

Machine lifecycle units include both their rendered state and the shared helper
in `restartTriggers`. Otherwise a helper-only repair updates settlement units
but leaves failed or inactive machine units untouched during a NixOS switch;
settlement then waits for instances whose corrected lifecycle command never ran.

Bounded-start orchestration targets and every wave gate set
`X-StopOnReconfiguration=true`. NixOS otherwise leaves active targets running
across a switch; reset failed machine units remain inactive, and already-active
gates let newly restarted settlements race ahead. Stopping and starting the
targets re-pulls the lifecycle units through the declared wave ordering.

The same admission check requires a size on the root disk when the project has
`limits.disk`. The parent-owned `abird-dev` default profile sets `root.size` to
32 GiB from `rootVolumeSize`, and its storage pool sets the default
custom-volume size to 32 GiB from `storageVolumeSize`. The names describe the
two Incus volume objects even though the root value is rendered through the
profile's `root` disk device. Because admission runs before storage-driver
defaults and a restricted remote may not expose that pool config, the
`abird-dev` projection also renders the same 32 GiB value into every `state`
device. The helper passes the rendered value explicitly when it creates each
custom volume and uses the visible pool default only as a fallback. It removes
this volume-creation-only `size` before attaching the non-root disk because
Incus accepts size quotas on custom volume creation but not on a non-root disk
device. Seven roots plus seven `state` volumes therefore declare 448 GiB before
the base image under the 512 GiB project ceiling. Disk-I/O rate limits remain
instance-owned and continue to reconcile after creation.

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

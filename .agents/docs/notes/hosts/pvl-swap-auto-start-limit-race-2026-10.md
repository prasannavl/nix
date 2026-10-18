# Pvl swap-auto start-limit race, 2026-10

## Symptom

`pvl-a1` hung 2026-10-16 21:40:55, recovered with SysRq+E. Precursors:
`systemd-resolved: Under memory pressure, flushing caches`, niri/libinput expiry
in the past.

Boot `657b5cd1` came up with **no swap**:

```text
prepare-btrfs-swap-subvolume-swap.service: Start request repeated too quickly.
prepare-btrfs-swap-subvolume-swap.service: Failed with result 'start-limit-hit'.
Dependency failed for /swap.
mkswap-swap-swap0.service: Job mkswap-swap-swap0.service/start failed with result 'dependency'.
swap-swap0.swap: Job swap-swap0.swap/start failed with result 'dependency'.
swap.mount: Job swap.mount/start failed with result 'dependency'.
systemd-oomd[...]: No swap; memory pressure usage will be degraded
```

Swap is `nofail`, so boot succeeded and the loss was silent.

## Race

- `prepare-btrfs-swap-subvolume-swap.service`: `Type=oneshot`,
  `RemainAfterExit` unset, pulled in by `requiredBy = [swap.mount]` (hard
  `Requires=`/`After=`).
- No retained state → every fresh start request for the swap chain re-executes it.
- `swap.mount` start requests pile up while the early-boot device/udev phase
  settles, executing only after that churn stops.
- Cliff: systemd defaults `StartLimitBurst=5` inside `StartLimitIntervalSec=10s`.

`pvl-a1` prepare starts per boot (kernel log, `systemd[1]` messages):

| Boot                   | starts | span   | `Mounting /swap` | outcome                      |
| ---------------------- | ------ | ------ | ---------------- | ---------------------------- |
| `cdab3f68` 10-04       | 4      | 0.59 s | after 4th        | swap active                  |
| `f3c18757` 10-13       | 4      | 0.79 s | after 4th        | swap active                  |
| `657b5cd1` 10-16 20:33 | 5      | 0.84 s | never            | **start-limit-hit, no swap** |
| `dca0fb1f` 10-17 09:26 | 5      | ~1 s   | never            | **start-limit-hit, no swap** |
| `f598d534` 10-17 12:45 | 5      | 0.62 s | never            | **start-limit-hit, no swap** |

Four re-runs in ~1 s are harmless; five wedge the unit and cascade the chain.
The count is timing-dependent per boot → the same generation worked for days,
then failed.

## Host comparison

Same generation (`26.05.20261008.7c8764b`), same generated unit shape
(`RemainAfterExit=no`, `RequiredBy=swap.mount`, burst 5 / 10 s):

| Host     | prepare starts/boot | `start-limit-hit` | panel backlight              |
| -------- | ------------------- | ----------------- | ---------------------------- |
| `pvl-l5` | 1-2 (stable)        | 0                 | nvidia EC, healthy           |
| `pvl-x2` | 2-3 (stable)        | 0                 | none                         |
| `pvl-a1` | 3-5 (varies)        | 4 (last 10 boots) | nvidia EC, broken (6879)     |

Re-requests only land in the stage-2 window between `Reached target Preparation
for Local File Systems` and `Mounting /swap`:

| Host     | window                                | device/target events inside                                              |
| -------- | ------------------------------------- | ------------------------------------------------------------------------ |
| `pvl-x2` | 0.61 s                                | Sound Card only (TPM2 already processed before local-fs-pre)             |
| `pvl-l5` | 0.98 s                                | TPM2, backlight slice + 1 success, RF-kill, Sound Card                   |
| `pvl-a1` | never mounts (chain failed at 1.14 s) | TPM2, backlight slice + 5 failing starts + ASUS kbd, RF-kill, Sound Card |

So the count tracks udev/device job churn in that window — per-host timing and
hardware inventory, not configuration. `pvl-a1` has the longest window, the
largest event inventory, and a broken EC backlight unit guaranteeing extra
re-triggers (11-501 starts/boot, `EC backlight control failed: AE_NOT_FOUND`).
Backlight count does not correlate 1:1 (`pvl-a1` boot `-3`: 26 backlight starts,
3 prepare starts) → amplifier, not sole cause. Fixing the backlight reduces
pressure but does not remove the race.

## Blast radius

- Hard `Requires=` → one trip fails `swap.mount`, then
  `mkswap-swap-swap0.service` and `swap-swap0.swap`.
- `nofail` only keeps `multi-user.target` reachable; the loss stays silent.
- No swap → `systemd-oomd` no-op, no slice sets
  `ManagedOOMMemoryPressure=kill` → memory pressure stalls the host.

## Fix

`lib/swap-auto.nix`: per-boot one-shot instead of stateless per-mount action.

- `RemainAfterExit = true` — after success the subvolume exists, so later start
  requests see the dependency active and skip it. Failed runs stay inactive, so
  a later mount attempt (live `switch-to-configuration`) still retries; the
  2026-08 migration contract holds.
- `StartLimitIntervalSec = 0` — the idempotent provisioner can never be wedged.

Supersedes the 2026-08 wording "every new mount attempt rechecks the subvolume
without retaining service state"; the rest of that contract is unchanged.

## Second defect: `pvl-a1` backlight storm

- udev starts `systemd-backlight@backlight:nvidia_wmi_ec_backlight.service` via
  `SYSTEMD_WANTS` on every device event; each failed restore re-triggers the
  next. Writes fail at firmware level (`AE_NOT_FOUND`).
- Retained journal:

| Result                                 | Count |
| -------------------------------------- | ----- |
| `Failed with result 'exit-code'`       | 5099  |
| `Failed with result 'start-limit-hit'` | 1780  |
| Successful runs of this instance       | 0     |

- Every `Finished Load/Save Screen Backlight Brightness` line belongs to a
  superseded device (`backlight:nvidia_0`, 6 lines, last 2026-07-18) or the
  working ASUS keyboard LED (61 lines) → the panel instance never worked.
- Each trigger costs five failed starts inside the same window, re-running
  unrelated boot one-shots.

`lib/devices/asus-fa401wv.nix` skips the instance while that device exists:

```nix
systemd.services."systemd-backlight@backlight:nvidia_wmi_ec_backlight" = {
  overrideStrategy = "asDropin";
  unitConfig.ConditionPathExists = "!/sys/class/backlight/nvidia_wmi_ec_backlight";
};
```

- Skipped, not failed → stays out of `systemctl --failed`, udev cannot retry.
- `overrideStrategy = "asDropin"` required: the package ships the
  `systemd-backlight@.service` template, not this instance; a full generated
  unit would shadow it. Verified output is
  `...@backlight:nvidia_wmi_ec_backlight.service.d/overrides.conf` with the
  template present.
- `pvl-l5` exposes the same device name but writes succeed → keeps the
  unmodified template.
- Trade-off: systemd save/restore for that one device is gone. Firmware
  brightness keys and logind sysfs writes unaffected; userspace writes already
  fail with `EIO`.
- Making brightness work needs an interactively validated backend change
  (`acpi_backlight=`); not attempted from a remote host.
- Nixbot `ignoredFailedSystemUnits` entry for the unit now redundant, left in
  place.

## Validation

- `lib/tests/swap-auto.nix`: asserts `RemainAfterExit == true`,
  `StartLimitIntervalSec == 0`.
- `lib/tests/swap-auto-vm.nix`: counts provisioner executions in the boot
  journal; one run for the live-switch node and each boot of the cold-boot node
  (including after power cycle), zero where the mount is already active, and no
  extra run after stopping/starting the mount chain. Passes.
- `lib/tests/swap-auto-remote-vm.nix`: existing boot-safety contract — with
  injected preparation, swapfile, and activation failures, cold boot and live
  switch reach `multi-user.target` with `sshd`/`tailscaled` active and no swap;
  the fix adds no new `Requires=` on `local-fs.target`/`multi-user.target`.
- Remote-recovery test not completed here: its VMs loop on public
  `tailscale.com` `bootstrapDNS` (`network is unreachable`) until the 1-hour
  timeout. Injected failures behaved as designed (`swapon: /swap/swap0:
  skipping - it appears to have holes`, `swapon: cannot open /swap/swap0`);
  re-run where test VMs have egress.

## Outstanding

- `btrfs-swap-auto.target` (`wantedBy = multi-user.target`,
  `wants = swap-swap0.swap`) duplicates the fstab-generated
  `swap.target -> swap-swap0.swap` edge → a second want-path and more
  re-requests during boot.
- Nothing reports "swap not active" after boot; a health check would have
  caught three consecutive no-swap boots.

## Live state

Diagnosis was read-only (`journalctl`, `systemctl show`, repo and
nixpkgs/systemd source). Fix not deployed: `pvl-a1` still has no active swap and
needs `systemctl reset-failed` plus a start of the swap chain, or a reboot onto
the new generation.

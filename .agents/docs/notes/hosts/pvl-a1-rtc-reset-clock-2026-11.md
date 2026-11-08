# RTC reset put `pvl-a1` 390 days behind (2026-11-07)

## Symptom

Cold boot at 19:06 IST ran with the clock at `2025-10-13 05:34:25 IST` for 2 h
56 m: TLS failed everywhere
(`x509: ... not yet valid: current time
2025-10-13T05:34:37+05:30 is before 2026-10-02T04:46:35Z`),
tailscaled logged out, dotlink's tunnel died, `uptime`/`last` claimed a 2025
boot, journald rotated with out-of-order timestamps. A manual set plus NTP fixed
it at 22:02:51.

## Root cause

1. The machine was suspended at 15:37:55 on a battery already at 0 % (UPower:
   `19 %` at 14:41, `0 %` at 15:23) and never resumed; power was cut.
2. On the next boot the CMOS RTC read the **firmware default**
   `2025-10-13T00:04:25Z`, i.e. the BIOS build date
   (`DMI: BIOS FA401WV.322
   10/13/2025`). The same value appeared on
   2026-09-19 (`...T00:04:58Z`), so the coin cell has lost the RTC at least
   twice.
3. The clock then stayed wrong for the whole boot because of an ordering race
   (below) and no NTP.
4. Nothing self-healed: NTP was blocked until 22:02 (`systemd-timesyncd` logged
   only `Network configuration changed` up to 19:32, then silence), and the
   wrong-past clock breaks the DNSSEC/TLS paths NTP depends on.

## Race (kernel log, monotonic)

```text
2.336s  System time advanced to built-in epoch: Tue 2026-03-17 19:55:52 UTC
5.736s  System time advanced to timestamp on /var/lib/systemd/timesync/clock:
        Sat 2026-11-07 15:37:17 IST            # correct, restored by PID 1
6.017s  rtc_cmos: setting system clock to 2025-10-13T00:04:25 UTC
6.020s  Time jumped backwards, rotating.
```

`rtc_cmos` is `CONFIG_RTC_DRV_CMOS=m` and was not in the initrd, so
`RTC_HCTOSYS` runs after PID 1 restores the last known time from the timesync
clock file. With a sane RTC both values agree; with a reset RTC the late read
wins.

## Fix

- `lib/boot.nix`: `boot.initrd.availableKernelModules = ["rtc_cmos"]`, so the
  RTC is read before userspace restores the clock file.
- Hardware: replace the CMOS coin cell. Verify by powering off, unplugging AC,
  pulling the battery for a minute, then booting: a dead cell reproduces
  `setting system clock to 2025-10-13...`.
- Avoid the trigger: never lid-suspend at 0 % battery
  (`HandleLidSwitch =
  "suspend"`); hybrid-sleep is currently broken (`s2idle`
  returns EIO on a flat pack).

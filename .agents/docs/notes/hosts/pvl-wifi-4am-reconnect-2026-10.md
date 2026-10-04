# Pvl fleet 04:00 WiFi reconnect latency

## Context

A nightly scheduled router/AP restart at about `04:00:17` deauthenticates every
WiFi client. On 2026-10-01 the recovery time differed sharply by host:

- `pvl-l5` (WiFi, MediaTek MT7921): deauth `04:00:17.6`, reconnected
  `04:20:51.3` — **20m34s**.
- `pvl-a1` (WiFi, MediaTek MT7922): deauth `04:00:17.6`, reconnected
  `04:05:45.9` — **5m28s**.
- `pvl-x2` (Ethernet `eno1` primary, WiFi `wlan0` backup): wired link down
  `04:00:25.5` → up `04:02:51.3` (**2m26s**); WiFi reassociated `04:03:20.4`.

All three hosts associate to the same AP BSSID `9c:53:22:83:1f:46` (5 GHz
channel 44, WPA3-Personal). `pvl-l5` and `pvl-a1` share the `mt7921e` driver;
`pvl-x2` uses `mt7925e`.

## Root cause

Reconnect latency is dominated by **iwd's disconnected-state periodic scan
schedule** (not DHCP, DNS, or Tailscale). The relevant iwd 3.12 behavior is in
`src/scan.c`:

- `[Scan] InitialPeriodicScanInterval` defaults to `10` seconds.
- `MaximumPeriodicScanInterval` defaults to `300` seconds.
- After each completed periodic scan, the timer is re-armed with the current
  interval; each timer expiry doubles the interval and queues the next scan,
  capped at the maximum.

That yields scan start times from the disconnect of approximately
`0, 15, 40, 85, 170, 335, 640, 945, 1250, 1555 ...` seconds. A client can only
reconnect on one of those scans, so reconnect times are **quantized** to about
`1.3, 2.7, 5.4, 10.5, 15.5, 20.6, 25.6` minutes and then 5-minute steps.

The Pvl config (`lib/network-wifi.nix`) sets only
`networking.networkmanager.wifi.backend = "iwd"` and
`networking.wireless.iwd.settings` (`AddressRandomization`, `AutoConnect`); none
of the `[Scan]` intervals are configured, so the 10 s → 300 s backoff applies.
`services.host-network-qos` (pvl-x2) and the wired path are unrelated to this
latency.

The `connect-failed, status: 53` logged on every first reconnect is
`MMPDU_STATUS_CODE_INVALID_PMKID`: the normal WPA3-SAE PMKSA-cache fallback
after the AP loses its PMKSA cache on reboot. iwd strips the stale PMKSA and
retries the same BSS immediately, so it does **not** trigger the iwd BSS
blacklist (`src/blacklist.c`) and is not part of the delay.

## Trigger for the late-September regime change

The regime change was caused by an **AP-side SSID reconfiguration at
`2026-09-22 00:24`, not by a host update**. At `00:24:19` every client received
`Received Deauthentication event, reason: 8, from_ap: true`, and `00:25:56` a
reason-4 (beacon loss) followed: the AP cycled its radios and came back with a
changed SSID layout.

The rename itself is visible directly in the iwd logs:

```text
Sep 21 04:04:24  pvl-l5  connect-info  ssid: PVL-Riverside,     bss: 9c:53:22:83:1f:47   # 2.4 GHz, old
Sep 22 00:29:02  pvl-a1  connect-info  ssid: PVL-Riverside-2G,  bss: 9c:53:22:83:1f:47   # same BSSID, new SSID
```

So the 2.4 GHz BSSID `9c:53:22:83:1f:47` stopped advertising `PVL-Riverside` and
started advertising `PVL-Riverside-2G`. After that, `PVL-Riverside` exists only
on the 5 GHz BSSID `9c:53:22:83:1f:46` (channel 44, confirmed with
`nmcli -f SSID,BSSID,CHAN,FREQ`).

The hosts' NetworkManager profile is `802-11-wireless.ssid = PVL-Riverside`,
band `--`, channel `0` — band-agnostic and **with no `PVL-Riverside-2G`
profile**. Before the rename the nightly reconnect landed on the 2.4 GHz
`PVL-Riverside` BSS as soon as that radio returned (~1 min); after the rename
the hosts must wait for the 5 GHz radio. `pvl-x2`'s own `wlan0` reassociation to
`.46` at `04:03:20` on 2026-10-01 shows the 5 GHz BSS is not associable until
roughly 3 minutes after the restart, which lands in the `5.4`-minute iwd backoff
slot and (on a scan miss) the `10.5`/ `20.6` slots.

## 2026-10-01 sequence

```text
04:00:17.62  all WiFi clients see "Connection to AP ... lost" (kernel);
             iwd: deauth reason 4, connected -> disconnected -> autoconnect_full
04:00:25.47  pvl-x2 eno1 (wired to the router) Link Down
04:02:51.26  pvl-x2 eno1 Link Up  (router wired side back, +2m26s)
04:03:16-19  pvl-x2 wlan0 SA Query timeout -> reassociate
04:03:20.43  pvl-x2 wlan0 associated  (AP 5 GHz confirmed usable)
04:05:45.94  pvl-a1 wlan0 reconnected  (caught the ~310s scan slot)
04:20:51.34  pvl-l5 wlan0 reconnected  (caught the ~1210s scan slot)
             pvl-l5 tailscaled/derp recovered immediately after
```

`pvl-a1` proved the AP was usable from `04:03:20`, yet `pvl-l5` logged **no**
`connect-info` between `04:00:18` and `04:20:51`, so its periodic scans did not
present a usable BSS during the intervening slots. `pvl-l5` has a weaker signal
(`-60` dBm vs `pvl-a1` `-53` dBm) and older MT7921 firmware (`20260224110949` vs
`pvl-a1` `20260724143402`), so a host-side scan/RF miss is the leading
explanation for it landing in the 20-minute slot rather than the 5-minute slot;
the backoff mechanism above is what converts any miss into 5-10 extra minutes.

## Historical pattern

Daily 04:00 reconnect gap in minutes (iwd, persisted journal):

```text
night    l5     a1     x2
09-09   1.3    1.4      -
09-10   2.7    1.4    1.4
09-14   5.5    1.4    1.4
09-18   3.4    1.4    1.4
09-21   4.1    1.4      -
09-22   5.4   10.5      -
09-23  15.5      -    5.5
09-24  23.3   25.6      -
09-25   5.6    3.5    5.5
09-26  20.6   35.7   10.6
09-27   5.4    5.5   10.6
09-28  20.6    5.5   10.6
09-29  20.6   20.6   10.6
09-30   5.4    5.5   20.7
10-01  20.6    5.5      -
```

- Baseline (2026-05 through 2026-09-21): 04:00 reconnects were consistently
  `~1.3-2.7` min (occasionally 3-5) and landed on the 2.4 GHz BSS
  `9c:53:22:83:1f:47`. The router/AP came back within the first one or two
  backoff slots.
- Regime change (from about 2026-09-22): after the AP renamed its 2.4 GHz SSID,
  the 04:00 reconnect switched to the 5 GHz BSS `9c:53:22:83:1f:46`, and all
  three hosts jumped into the `5.4 / 10.5 / 15.5 / 20.6 / 25.6 / 35.7` slots.
- A histogram of all retained disconnect episodes (`pvl-l5` n=338, `pvl-a1`
  n=445, `pvl-x2` n=89) shows counts only at those quantized slots, confirming
  the periodic-scan schedule rather than a random fault.

## Remediation options

- Lower `networking.wireless.iwd.settings.Scan.MaximumPeriodicScanInterval` (for
  example `60`) and optionally `InitialPeriodicScanInterval` in
  `lib/network-wifi.nix`. This caps the worst-case post-restart reconnect at
  about one minute, at the cost of more scans while disconnected.
- Prefer a wired uplink for latency-critical hosts (the `pvl-x2` model); the
  router's wired side returned ~2.5 min after the restart regardless of WiFi
  backoff.
- Add a NetworkManager profile (or credentials) for `PVL-Riverside-2G` so hosts
  can fall back to the fast-returning 2.4 GHz radio, or rename the AP's 2.4 GHz
  SSID back to `PVL-Riverside` so the existing profile matches both bands.
- To confirm the cadence during the next 04:00 event, temporarily run iwd with
  debug logging (add `-d` to the `iwd` unit `ExecStart` via a drop-in) and watch
  `Arming periodic scan timer: <interval>` / `Periodic scan` messages.

## Evidence commands

```console
# per-host nightly gap
journalctl -u iwd --no-pager -o short-precise \
  | grep -E 'new: disconnected|new: connected|connect-info|connect-failed'

# kernel WiFi sequence and wired link
journalctl -k --since '2026-10-01 03:58' --until '2026-10-01 04:25' -o short-precise

# effective iwd config
cat /etc/iwd/main.conf
iwctl station wlan0 show
```

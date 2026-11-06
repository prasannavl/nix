# Timezone does not follow the WAN on `pvl-a1` / `pvl-l5`

## Symptom

Travel across a timezone border, and the clock keeps the timezone that was
computed at boot. GNOME appears to fix it "immediately"; niri does not.

## Root cause

`automatic-timezoned` is a pure event listener: it starts one geoclue client,
then applies `SetTimezone` for every `LocationUpdated` it receives. It has no
polling, no timer, and no NetworkManager hook.

geoclue (2.7.2) produces locations lazily:

- each client gets a private locator, but the location sources are process-wide
  singletons (`gclue-locator.c`);
- a source only queries when it starts at refcount 0->1, on WiFi BSS changes, or
  on a locate-URL reachability flip (`gclue-location-source.c`,
  `gclue-web-source.c`); otherwise a new client is just seeded with the cached
  location;
- the WiFi source is unusable on these hosts: NetworkManager runs on iwd
  (`lib/network-wifi.nix`) while geoclue only talks `wpa_supplicant`, so it
  degrades to a GeoIP-only query against beacondb (`gclue-locator.c`), ~25 km
  accuracy, and no BSS-driven refreshes ever happen.

Net effect: one location per client start. If no client holds the source, a
long-running `automatic-timezoned` is simply deaf.

Measured on `pvl-a1` on 2026-11-06 (booted 2026-11-05 in Singapore, by then in
India):

```console
$ timedatectl
Time zone: Asia/Singapore (+08, +0800)     # 2.5 h ahead of Asia/Kolkata
$ journalctl -u automatic-timezoned -b
Nov 05 16:22:43 automatic-timezoned[1669994]: Set timezone to "Asia/Singapore"
# nothing since, despite two NetworkManager restarts
```

Two on-demand geoclue queries each produced a fresh location, ~1 s after the
client started, which is only possible while no client holds the source:

```console
$ where-am-i          # geoclue demo client, City accuracy
Timestamp: Fri 06 Nov 2026 04:08:27 PM +08
$ where-am-i
Timestamp: Fri 06 Nov 2026 04:09:25 PM +08
```

Neither reached `automatic-timezoned`, so its locator is not subscribed.

## Why GNOME looks better than niri

GNOME has no timezone applier of its own: `gsd-datetime` in
gnome-settings-daemon 50.1 does not link geoclue, and `gnome-shell` never calls
`timedate1`. It only supplies a geoclue client at session start
(`libshell-18.so` links `GeoClue2`), which makes geoclue query, and the same
`automatic-timezoned` then applies the timezone. niri has no geolocation client
at all, so nothing re-triggers the chain.

## Fix

Restarting `automatic-timezoned` rebuilds client + locator, forcing one fresh
query and one `SetTimezone` - the same path that makes a reboot fix the clock.
Wired in `lib/locale.nix`, gated on `services.automatic-timezoned.enable`, so
every host with automatic timezones gets it (`pvl-a1`, `pvl-l5` today) and
static-timezone hosts stay inert:

- NetworkManager `connectivity-change` dispatcher event (no device filter,
  unlike `up`, which also fires for `tailscale0`/`incusbr0`);
- `powerManagement.resumeCommands`, since the NetworkManager restart in
  `lib/network-wifi.nix` does not guarantee a dispatcher event.

The unit also gets `Restart=on-failure` with a 30s delay: the daemon's loop is
`set_timezone(...)?`, so any error exits the process, and `try-restart` only
revives _active_ units - without this, one transient failure left timezone sync
dead until reboot.

No GNOME special case is needed: there the restart is redundant but harmless -
same daemon, same data source, and `SetTimezone` with an unchanged value is a
no-op. It also does not touch geoclue's agent (the `Requires=` edge runs the
other way), so the session's "Geolocation service in use" state does not
flicker.

Country-level accuracy is all this needs, so the coarse GeoIP source is
adequate. Known limits: a roaming SIM keeps the home-country public IP, and an
unchanged connection across a border produces no event at all.

## Validation

After the next border crossing or resume:

```console
$ journalctl -u automatic-timezoned -n 4
Nov 07 09:12:04 pvl-l5 systemd[1]: Starting Automatically update system timezone based on location...
Nov 07 09:12:04 pvl-l5 automatic-timezoned[1234]: [INFO  automatic_timezoned] Starting automatic-timezoned 2.0.126...
Nov 07 09:12:11 pvl-l5 automatic-timezoned[1234]: [INFO  automatic_timezoned] Set timezone to "Asia/Kolkata"
```

Expect that pair after each resume or border crossing. NetworkManager's
dispatcher unit stays active across many events, so its start/stop lines are not
a usable signal.

# pvl DBus Broker Policy Cleanup

## Context

After switching `pvl-x2` and `pvl-a1` from `dbus-daemon` to `dbus-broker`, the
broker logs exposed package policy fragments that reference Debian-style
accounts or groups absent on NixOS.

## supergfxctl

`supergfxctl` installs `data/org.supergfxctl.Daemon.conf` with both `sudo` and
`wheel` group policy stanzas. NixOS uses `wheel` as the privileged admin group,
and this repo grants `pvl` sudo access through `wheel`.

Because `sudo` is not a NixOS base group, `dbus-broker-launch` reports an
invalid group-name warning while parsing the policy. The local overlay removes
only the `group="sudo"` stanza from the installed `supergfxctl` D-Bus policy and
leaves the existing `wheel` stanza intact.

## PulseAudio

The repo runs PipeWire with Pulse compatibility enabled and explicitly disables
the legacy PulseAudio service. Installing `pkgs.pulseaudio` for client tools
still brings the system-wide PulseAudio D-Bus policy fragment, which references
the Debian `pulse` system user. Do not create a `pulse` user just to silence
that warning unless system-wide PulseAudio is intentionally enabled.

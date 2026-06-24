# pvl-l5 generation mismatch symptoms

## automatic-timezoned finding

On 2026-06-24, `pvl-l5` had `services.automatic-timezoned.enable = true` in
`hosts/pvl-l5/default.nix`, and evaluating the flake target showed:

```console
$ nix eval --impure --json --expr 'let flake = builtins.getFlake "path:/home/pvl/src/nix"; in { serviceEnable = flake.nixosConfigurations.pvl-l5.config.services.automatic-timezoned.enable or null; systemdEnable = flake.nixosConfigurations.pvl-l5.config.systemd.services.automatic-timezoned.enable or null; unitNames = builtins.filter (n: builtins.match ".*automatic-timezoned.*" n != null) (builtins.attrNames flake.nixosConfigurations.pvl-l5.config.systemd.units); }'
{"serviceEnable":true,"systemdEnable":true,"unitNames":["automatic-timezoned-geoclue-agent.service","automatic-timezoned.service"]}
```

The same evaluation built to
`/nix/store/1p0wzd2ngaw5hpa5pxn7ndzcyhk6j09x-nixos-system-pvl-l5-26.05.20260618.e8210c6`,
which contains:

- `etc/systemd/system/automatic-timezoned.service`
- `etc/systemd/system/automatic-timezoned-geoclue-agent.service`

The live machine was still booted into the older installed generation:

```console
$ readlink -f /run/current-system
/nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05.20260611.a037402

$ readlink -f /nix/var/nix/profiles/system
/nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05.20260611.a037402
```

That older generation has no `automatic-timezoned` unit:

```console
$ systemctl list-unit-files 'automatic-timezoned*' --no-pager
UNIT FILE STATE PRESET

0 unit files listed.

$ systemctl status automatic-timezoned.service --no-pager
Unit automatic-timezoned.service could not be found.
```

## Interpretation

If deploy output says `automatic-timezoned.service` was started but the local
`systemctl` manager cannot find it afterward, first compare the evaluated target
generation with `/run/current-system` and `/nix/var/nix/profiles/system`.

In this case, the repo target includes the service, but the installed and booted
system profile does not. The symptom is a generation/profile mismatch, not a
hidden inactive service.

## Root cause

Nixbot did live-activate the target system, but it did not make that target the
persistent system profile or boot default.

The deploy journal showed nixbot invoking the built store path directly:

```text
/nix/store/1p0wzd2ngaw5hpa5pxn7ndzcyhk6j09x-nixos-system-pvl-l5-26.05.20260618.e8210c6/bin/switch-to-configuration switch
```

That command was launched from `pkgs/tools/nixbot/nixbot.sh` via
`activate_prepared_system_path`, which constructs:

```text
NIXOS_INSTALL_BOOTLOADER=0 systemd-run ... <system-path>/bin/switch-to-configuration switch
```

The direct `switch-to-configuration switch` path was enough to restart units and
make the runtime look switched. It started `automatic-timezoned.service` at
`19:35:56` and the service logged:

```text
Starting automatic-timezoned 2.0.126...
Set timezone to "Asia/Kolkata"
```

At `19:36:47`, the local desktop requested a reboot:

```text
noctalia-shell: Compositor Reboot requested
systemd-logind: The system will reboot now!
```

The next boot command line used the old generation:

```text
init=/nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05.20260611.a037402/init
```

Boot activation then removed the new-only `automatic-timezoned` user/group,
because that old generation does not declare the service.

So nixbot's `Result: success` was correct for runtime activation and health
checks before reboot. The missing part was persistence: there was no new
`/nix/var/nix/profiles/system-31-link`, and `/nix/var/nix/profiles/system`
remained pointed at `system-30-link`.

## Noctalia dock finding

The same mismatch explained the Noctalia dock not appearing after a switch and
reboot on 2026-06-24.

The current checkout evaluated
`nixosConfigurations.pvl-l5.config.home-manager.users.pvl.programs.noctalia-shell.settings.dock`
with the dock enabled. Its generated settings source contained the full enabled
dock attrset, including `enabled = true`, `position = "top"`, pinned apps, and
indicator settings.

The live `~/.config/noctalia/settings.json` was still a Home Manager symlink, so
the file was not unmanaged mutable runtime drift. It linked through the active
Home Manager generation to an older settings source with only:

```json
{
  "dock": {
    "enabled": false
  }
}
```

The journal showed nixbot directly activating the current evaluated system at
`2026-06-24 19:35:17`:

```text
switching to system configuration /nix/store/1p0wzd2ngaw5hpa5pxn7ndzcyhk6j09x-nixos-system-pvl-l5-26.05.20260618.e8210c6
finished switching to system configuration /nix/store/1p0wzd2ngaw5hpa5pxn7ndzcyhk6j09x-nixos-system-pvl-l5-26.05.20260618.e8210c6
```

The host rebooted at `19:36:47`. On the next boot, `initrd-nixos-activation`
reported:

```text
booting system configuration /nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05.20260611.a037402
```

After that boot, `/run/current-system`, `/run/booted-system`, and
`/nix/var/nix/profiles/system` all pointed at the older `h6ai32...` generation,
and `bootctl status` reported `nixos-generation-30.conf` as the current entry.

Interpretation: the runtime switch briefly activated the Noctalia dock-enabled
config, but the reboot selected the older boot/profile generation. Home Manager
then reactivated that older generation and relinked the old Noctalia settings,
so the dock disappeared.

Validation sequence for similar desktop-setting reports:

1. Compare `readlink -f /run/current-system`, `readlink -f /run/booted-system`,
   and `readlink -f /nix/var/nix/profiles/system`.
2. Compare the current checkout's evaluated toplevel with `/run/current-system`:
   `nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel --raw`.
3. Compare the evaluated Home Manager setting with the linked live file:
   `nix eval .#nixosConfigurations.pvl-l5.config.home-manager.users.pvl.programs.noctalia-shell.settings.dock --json`
   and `jq '.dock' ~/.config/noctalia/settings.json`.
4. Check the deploy and reboot window in the journal for direct
   `switch-to-configuration switch` activation followed by booting an older
   generation.

A direct store-path `switch-to-configuration switch` can be enough for the
running session, but it is not enough if the machine later reboots into an older
installed generation. Make the intended generation the system profile and boot
entry before rebooting when the change needs to survive boot.

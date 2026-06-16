# pvl-l5 NVIDIA CDI Driver Bump 2026-06

## Incident

On June 16, 2026, a `pvl-l5` deploy failed while switching to
`/nix/store/jxylyn67a9f7vmml9wxhqxbbgs100z4m-nixos-system-pvl-l5-26.05.20260611.a037402`.
The failing unit was `nvidia-container-toolkit-cdi-generator.service`.

The staged checkout had updated `lib/ext/nvidia/default.nix` from NVIDIA
`595.71.05` to `595.80`. During `switch`, systemd restarted the CDI generator
from the new generation, so it loaded:

- `/nix/store/2058xcxbwp1l5kr53kzpvsxysg07f1nn-nvidia-x11-595.80/lib/libnvidia-ml.so.595.80`
- `/nix/store/2058xcxbwp1l5kr53kzpvsxysg07f1nn-nvidia-x11-595.80/lib/libnvidia-sandboxutils.so.595.80`

The live kernel still had the old NVIDIA module loaded:

```text
NVRM version: NVIDIA UNIX Open Kernel Module for x86_64 595.71.05
```

NVML therefore failed with `Driver/library version mismatch`, causing the
oneshot CDI generator to exit nonzero and `switch-to-configuration` to return
failure.

## Current State

After the failed switch, `/nix/var/nix/profiles/system` pointed at the new
`595.80` generation, while `/run/current-system` still pointed at the previous
`595.71.05` runtime. Re-running the CDI generator from the previous runtime
succeeded and regenerated `/run/cdi/nvidia-container-toolkit.json` with the
matching `595.71.05` stack.

After rebooting, `/run/current-system` and `/nix/var/nix/profiles/system` both
pointed at the `595.80` generation, `nvidia-smi` reported `595.80`, and the CDI
generator completed successfully with `Generated CDI spec with version 1.1.0`.
No system or user units were failed, and `systemctl is-system-running` reported
`running`.

## Resolution

For the immediate incident, rebooting into the already-selected new generation
should load the matching `595.80` kernel module and allow the CDI generator to
run successfully at boot. Verify with:

```sh
nvidia-smi
cat /proc/driver/nvidia/version
systemctl status nvidia-container-toolkit-cdi-generator.service
```

The durable repo fix sets:

```nix
systemd.services.nvidia-container-toolkit-cdi-generator.restartIfChanged = false;
```

at the shared NVIDIA hardware module boundary. This avoids restarting the CDI
generator during `nixos-rebuild switch` when the NVIDIA user-space package has
changed but the loaded kernel module cannot change until reboot. The upstream
NixOS module already starts the generator at boot and has a udev rule to restart
it when `/dev/nvidia` appears, so regeneration still happens once kernel and
user-space driver versions match.

The same boot review also found a repo-owned kernel warning:

```text
mt7921e: unknown parameter 'power_save' ignored
```

The current `mt7921e` module exposes only `disable_aspm`, while `mt7921_common`
exposes `disable_clc`, so the stale `power_save=0` line was removed from the
`mt7921e` options.

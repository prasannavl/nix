# Podman Compose Container PATH 2026-07

The shared `services.podman-compose` helper environment must keep NixOS command
paths for host-side helper execution while also including standard container
path directories:

```text
/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Some container images use relative entrypoints such as `docker-entrypoint.sh`.
If Podman creates the container with only the host/Nix helper `PATH`, those
entrypoints can fail even though they exist inside the image under normal
container paths.

Treat the helper PATH as part of the recreate input. Existing containers created
during a bad-PATH generation can keep the old `Config.Env` and be restarted by
Podman before the helper has a chance to inspect them. A PATH compatibility
change must therefore force fresh container creation, not just a unit restart.

The per-user `podman-rootless-idmap-migrate-<user>.service` should also behave
as a satisfied preflight gate. Keep it as `RemainAfterExit = true`, with normal
restart triggers, so a successful subordinate uid/gid map check satisfies later
dependent compose starts until the next relevant unit restart or
reconfiguration.

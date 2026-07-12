# Host Manager Operations 2026-07

`host-manager` supports host operations in addition to host generation, build,
live install, and delete:

```bash
scripts/host-manager.sh build HOST --store PATH
scripts/host-manager.sh generate HOST [--system=none|live|incus] [options]
scripts/host-manager.sh live-install HOST --wipe-disks [options]
scripts/host-manager.sh delete HOST [--force|--yes]
scripts/host-manager.sh ssh HOST [-- ssh-args...]
scripts/host-manager.sh reboot HOST [--dry-run] [--yes]
scripts/host-manager.sh gc HOST [--delete-older-than AGE|--all] [--dry-run] [--yes]
scripts/host-manager.sh clean:podman HOST [--dry-run] [--force-held] [--yes]
scripts/host-manager.sh clean:nixbot HOST [--dry-run] [--force-held] [--yes]
scripts/host-manager.sh logs HOST [--service SERVICE] [--since WHEN] [--lines N] [--follow]
scripts/host-manager.sh service start|stop|restart|status|logs SERVICE [--stack STACK|--host HOST] [--user USER] [--since WHEN] [--lines N] [--follow]
```

Operations use `hosts/nixbot.nix` as the SSH route inventory. By default,
interactive host operations use the current operator user rather than the nixbot
deploy user. Use `--user` to override the SSH user, or the systemd user for
service log/control actions.

Mutation safety:

- `reboot`, `gc`, `clean:podman`, and `clean:nixbot` require `--yes` before
  mutating a remote host.
- `service start`, `service stop`, and `service restart` require `--yes` unless
  `--dry-run` is set.
- `--dry-run` audits and prints intended cleanup without deleting state.
- Held lock paths are reported and preserved unless `--force-held` is supplied.
- `clean:podman` removes only unused anonymous 64-hex Podman volumes. It does
  not run global `podman volume prune` and does not remove named or mounted
  volumes.

`reboot HOST` SSHes to the addressed host and runs `systemctl reboot` there. It
does not call Incus on a parent host, so a guest target reboots itself.

`logs HOST` shows the system journal for the addressed host. With
`--service SERVICE`, it shows only that service on the addressed host and does
not perform service-registry host discovery.

`service start|stop|restart|status|logs SERVICE` resolves the service through
`lib/stacks/<stack>.nix` and defaults to the local `pvl` stack. Passing
`--host HOST` disables registry discovery and targets only that host. Once on
the host, host-manager prefers
`/run/current-system/share/podman-compose/control-registry.json` to discover the
generated systemd user, unit, and service name. If the registry entry is absent,
the local fallback is `pvl-${SERVICE}.service` running as user `pvl`.

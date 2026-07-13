# Host Manager Operations 2026-07

`host-manager` supports host operations in addition to host generation, build,
live install, and delete:

```bash
scripts/host-manager.sh build HOST|--host=HOST --store PATH
scripts/host-manager.sh generate HOST|--host=HOST [--system=none|live|incus] [options]
scripts/host-manager.sh live-install HOST|--host=HOST --wipe-disks [options]
scripts/host-manager.sh delete HOST|--host=HOST [--force|--yes]
scripts/host-manager.sh ssh HOST|--host=HOST [-- ssh-args...]
scripts/host-manager.sh reboot HOST|--host=HOST|--host=all [--jobs N] [--dry-run] [--yes]
scripts/host-manager.sh gc HOST|--host=HOST|--host=all [--jobs N] [--delete-older-than AGE|--all] [--dry-run] [--yes]
scripts/host-manager.sh clean:deploy HOST|--host=HOST|--host=all [--jobs N] [--dry-run] [--force-held] [--yes]
scripts/host-manager.sh clean:podman HOST|--host=HOST|--host=all [--jobs N] [--dry-run] [--force-held] [--yes]
scripts/host-manager.sh clean:nixbot HOST|--host=HOST|--host=all [--jobs N] [--dry-run] [--force-held] [--yes]
scripts/host-manager.sh logs HOST|--host=HOST [--service SERVICE] [--since WHEN] [--lines N] [--follow]
scripts/host-manager.sh service start|stop|restart|status|logs SERVICE [--stack STACK|--host HOST] [--user USER] [--since WHEN] [--lines N] [--follow]
```

Operations use the effective nixbot host transport inventory: `hosts/nixbot.nix`
overlaid with sibling `hosts/nixbot.override.nix` when that override file
exists. For SSH, host-manager prefers per-host `operatorUser`/`operatorKey`,
then `config.hostDefaults.operatorUser` / `operatorKey`, and finally the current
operator user. Use `--user` to override the SSH user, or the systemd user for
service operations; explicit `--user` does not reuse an inventory operator key
for a different user.

Host-manager generates a temporary SSH config for inventory-owned proxy chains
so nested `proxyJump` routes do not depend on ambient `~/.ssh/config` aliases.
Host-key checking remains strict. Generated entries include inventory operator
identity files when configured, and use `HostKeyAlias` only when that logical
host alias already exists in known_hosts; otherwise SSH validates the concrete
target address normally.

Mutation safety:

- For host-targeted commands, positional `HOST` and `--host=HOST` are
  equivalent. Use the flag form for fleet selectors or generated command lines.
- `reboot`, `gc`, `clean:deploy`, `clean:podman`, and `clean:nixbot` require
  `--yes` before mutating a remote host.
- `service start`, `service stop`, and `service restart` require `--yes` unless
  `--dry-run` is set.
- `--dry-run` audits and prints intended cleanup without deleting state.
- Held lock paths are reported and preserved unless `--force-held` is supplied.
- `reboot`, `gc`, `clean:deploy`, `clean:podman`, and `clean:nixbot` accept
  `--host=all` to target every effective nixbot inventory host. Bare `--all`
  remains a command-specific flag only; for `gc`, it runs
  `nix-collect-garbage -d` for the selected host, including with `--host=all`.
- `--host=all` maintenance runs use `--jobs N` for host parallelism, defaulting
  to 8. Single-host runs stay foreground and ignore the parallelism setting.
- `clean:deploy` runs the nixbot and Podman cleanup paths together.
- `clean:podman` removes only unused anonymous 64-hex Podman volumes. It does
  not run global `podman volume prune` and does not remove named or mounted
  volumes.
- Host-manager `clean:*` is the canonical target-host lock cleanup surface.
  Nixbot owns local operator-machine cleanup only.

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

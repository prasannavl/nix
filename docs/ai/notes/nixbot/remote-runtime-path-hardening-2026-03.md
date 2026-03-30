# Remote Runtime PATH Hardening (2026-03)

## Context

`nixbot` deploys target NixOS machines that may be minimal images or transient
execution contexts with a sparse environment.

The activation-context machine-age-identity probe exposed the broader issue:
some remote helpers relied on ambient `PATH`, `sh`, `bash`, `readlink`,
`mktemp`, `rm`, and similar tools being discoverable in non-interactive SSH,
`sudo`, or `systemd-run` contexts.

That assumption is weaker on:

- bare NixOS hosts
- first-boot/base images
- Incus guest templates
- transient units whose inherited `PATH` only contains systemd binaries

## Decision

Treat `/run/current-system/sw/bin` as the explicit remote runtime contract for
NixOS targets.

In `pkgs/nixbot/nixbot.sh`:

- critical remote shell entrypoints now use `/run/current-system/sw/bin/bash` or
  `/run/current-system/sw/bin/sh`
- remote helper PATH setup now prefixes `/run/current-system/sw/bin`
- direct remote calls to core tools like `readlink`, `mktemp`, and `rm` use
  explicit `/run/current-system/sw/bin/...` paths in critical deploy paths

## Operational Effect

- deploy, snapshot, rollback, parent-readiness, and summary helpers are more
  robust against thin remote environments
- `nixbot` relies less on login-shell behavior and less on distro-default PATH
  composition
- future remote helpers should prefer the same explicit runtime contract rather
  than assuming ambient command discovery

## Source Of Truth Files

- `pkgs/nixbot/nixbot.sh`

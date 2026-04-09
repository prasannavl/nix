# Nixbot SSH Config Isolation And Bastion Target (2026-04)

## Scope

Record the fix for local operator SSH config leaking into `nixbot` deploy
transport resolution.

## Durable decisions

- `nixbot` SSH invocations must ignore ambient user SSH config by passing
  `-F /dev/null` on:
  - deploy/bootstrap SSH contexts
  - bastion-trigger SSH
  - generated proxy-command helper scripts
  - repo refresh `GIT_SSH_COMMAND`
- Repo deploy target definitions must not depend on operator-local SSH aliases.
- `hosts/nixbot.nix` should use the real bastion hostname `z.bastion.com` for
  `gap3-gondor` instead of the local alias `gap3-gondor`.

## Failure mode addressed

- A local `~/.ssh/config` entry mapped `gap3-gondor` to `z.bastion.com`.
- `nixbot` already isolated `known_hosts`, but it still allowed SSH to read the
  operator config, so the runtime target silently changed underneath the repo.
- That produced host-key verification failures against `z.bastion.com` during
  snapshot/bootstrap even though the repo intended to own SSH transport state.

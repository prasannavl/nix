# Nixbot Bastion Known Hosts Fallback (2026-03-09)

## Problem

GitHub Actions `nixbot` runs can fail before the bastion forced-command entry
point with:

- `Host key verification failed.`

The workflow passes `DEPLOY_BASTION_KNOWN_HOSTS` from the
`NIXBOT_BASTION_KNOWN_HOSTS` secret when present, but some environments do not
have that secret populated. In those runs the bastion SSH client had no trusted
host key material, so the initial SSH connection to `pvl-x2` failed.

## Resolution

- Kept the explicit `DEPLOY_BASTION_KNOWN_HOSTS` / `--bastion-known-hosts`
  path as the preferred source.
- Moved fallback behavior into `scripts/nixbot-deploy.sh` so
  `configure_bastion_trigger_ssh_opts()` now runs `ssh-keyscan -H
  <bastion-host>` when no bastion known-hosts content is supplied.
- Kept strict host-key checking in both cases by always writing a dedicated
  temporary `known_hosts` file for the bastion SSH hop.
- Added an explicit failure if neither provided content nor `ssh-keyscan`
  yields host-key data.

## Effect

`--bastion-trigger` no longer hard-fails solely because
`NIXBOT_BASTION_KNOWN_HOSTS` is unset, while still preferring pinned host-key
material when it exists and remaining strict once host-key data is available.

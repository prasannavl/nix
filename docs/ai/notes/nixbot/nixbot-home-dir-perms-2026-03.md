# Nixbot Home Directory Permissions (2026-03)

## Context

- A containerized guest's deploy and snapshot probes connected as `nixbot` but
  emitted:
  - `Could not chdir to home directory /var/lib/nixbot: Permission denied`
  - `bash: /var/lib/nixbot/.bashrc: Permission denied`
- The deploy runner treated those probes as success because the remote commands
  still returned the expected current-system path, but the account state on the
  target was wrong.

## Decision

- Make the shared `lib/nixbot/default.nix` module enforce `/var/lib/nixbot` as a
  real `nixbot:nixbot` home directory on every host, not just bastion hosts.

## Change

- Added a base activation step:
  - `install -d -m 0755 -o nixbot -g nixbot /var/lib/nixbot`
- Added a matching tmpfiles rule:
  - `d /var/lib/nixbot 0755 nixbot nixbot -`

## Rationale

- Bastion hosts already did this in `lib/nixbot/bastion.nix`; non-bastion hosts
  still relied on user creation semantics, which were not sufficient for the
  containerized guest case.
- Keeping the fix in the shared module preserves the deploy contract: connecting
  as `nixbot` must provide a usable home directory before any shell startup or
  remote probe runs.

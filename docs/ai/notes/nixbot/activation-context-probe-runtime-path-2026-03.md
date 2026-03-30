# Activation Context Probe Runtime PATH (2026-03)

## Context

`nixbot` deploys started failing on normal hosts during the pre-activation
machine-age-identity visibility check, after the identity had already been
installed successfully.

Observed behavior:

- deploy logs showed repeated
  `Waiting for activation context to see host age identity ...`
- direct checks as `nixbot` confirmed `/var/lib/nixbot/.age/identity` existed,
  had the expected checksum, and was readable
- the transient-unit probe used by
  `wait_for_prepared_host_age_identity_activation_visibility()` failed with:
  `env: 'sh': No such file or directory`

## Root Cause

The activation-context probe launched:

- `systemd-run --wait --pipe --quiet --service-type=exec env DEST=... sh -c ...`

Transient units on these hosts had `PATH` limited to the systemd store path,
which did not include `sh`, `sha256sum`, or other normal shell utilities. That
made the validation helper fail before it ever checked the injected file, so the
retry loop always timed out.

## Decision

Make the activation-context probe explicit about its runtime environment:

- execute `/run/current-system/sw/bin/sh` inside `systemd-run`
- set `PATH=/run/current-system/sw/bin` for that transient unit

## Operational Effect

- activation-context validation now tests the intended file visibility instead
  of depending on the transient unit's sparse default `PATH`
- normal deploys no longer fail on hosts where `systemd-run` lacks a shell in
  its inherited environment

## Source Of Truth Files

- `pkgs/nixbot/nixbot.sh`

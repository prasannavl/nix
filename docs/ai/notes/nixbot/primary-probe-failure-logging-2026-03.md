# Nixbot Primary Probe Failure Logging (2026-03)

## Context

When `nixbot` fell back from the normal deploy user to the bootstrap user, the
operator could see that bootstrap was chosen but could not see why the primary
`nixbot@host` probe failed.

That made it hard to distinguish between host-key verification problems,
transient transport failures, and public-key auth failures.

## Decision

When the primary deploy probe fails, `pkgs/nixbot/nixbot.sh` must print the
captured probe stderr/stdout before falling back or retrying through the full
configured proxy chain.

The probe helper must capture that failure through an `if ...; then` branch
instead of running the retry helper as a bare command under `set -e`, because a
non-zero probe result would otherwise exit the helper before the captured output
is recorded.

## Effect

- direct primary failures now print the exact SSH failure before bootstrap
  fallback
- proxy-flattened runs now print the direct-path failure before retrying the
  full configured proxy chain
- if the full proxy-chain retry also fails, that failure is printed too
- self-target runs on the current host now log that they are using local
  execution, which makes it explicit that no SSH primary/bootstrap probe will
  run for that host

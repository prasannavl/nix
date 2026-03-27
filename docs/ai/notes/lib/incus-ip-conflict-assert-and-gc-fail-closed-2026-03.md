# Incus IP Conflict Assertion And GC Fail-Closed

## Context

A fresh review of `lib/incus.nix` found two correctness issues:

- static guest `ipv4Address` values were required but not checked for
  uniqueness, so two declared guests could silently share the same address
- the garbage-collection unit treated `incus list` failure as an empty list,
  which made Incus query failure look like a successful no-op GC run

## Decision

Fix both in `lib/incus.nix`:

- add an assertion that fails evaluation when multiple machines declare the same
  `ipv4Address`
- make the Incus GC unit fail closed when `incus list --format json` fails

## Operational Effect

- duplicate static guest IPv4 assignments are now caught during evaluation
  instead of surfacing later as ambiguous readiness or networking failures
- Incus GC now reports daemon/query failure to the caller instead of silently
  pretending there was nothing to collect

# Proxied Control Master Enable

## Context

`nixbot` had intentionally disabled SSH control-master reuse for proxied hosts
based on an earlier assumption that `ProxyCommand` chains were too fragile to
multiplex safely.

That assumption no longer matched the current implementation.

Live verification against the generated proxy wrapper showed that proxied
targets can reuse a shared master connection successfully for both:

- repeated `ssh` commands
- repeated `scp` transfers

This matters because parented child deploys otherwise open a burst of fresh SSH
handshakes for:

- connectivity probes
- file validation
- temp-file allocation
- `scp`
- remote install
- activation-context checks

## Decision

Enable control-master reuse for proxied primary and bootstrap SSH contexts too,
not just direct targets.

Also, when parented readiness is invalidated, remove the matching control
sockets so retries do not cling to a stale master connection from an unstable
post-switch window.

## Operational Effect

- proxied child deploy steps can reuse one established SSH transport instead of
  repeatedly re-handshaking through the parent
- this should reduce `kex_exchange_identification` resets during deploy
  preflight on parented hosts
- parented retry paths still fail closed because clearing `primary-ready` also
  clears the associated primary/bootstrap control sockets before re-probing

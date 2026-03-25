# Nixbot Bastion Self Target And Proxy Flattening (2026-03)

## Context

GitHub Actions enters the deploy flow through bastion forced-command ingress on
`pvl-x2`. Once the run is already executing on that bastion host, treating
`pvl-x2` as a normal remote SSH target is unnecessary and can fail during
post-switch reconnects and rollback.

The same issue applies to downstream guests that declare `proxyJump = "pvl-x2"`:
when the deploy process is already running on `pvl-x2`, keeping that leading hop
forces SSH back through bastion ingress instead of connecting directly to the
guest.

The CI failure signature that motivated this note included:

- forced-command bootstrap check failed
- failed to allocate remote temporary file for bootstrap key
- rollback on `pvl-x2` after a successful switch
- `Connection closed by 127.0.0.2 port 22` while reaching a guest through
  `proxyJump = "pvl-x2"` from a bastion-triggered run already executing on
  `pvl-x2`

## Decision

- Detect the current host at runtime from local hostname aliases.
- Match current-host identity by both names and resolved/local addresses so the
  rule still works when deploy targets or proxy hops are expressed as IPs or
  alternate DNS names.
- If the selected deploy target is the current host during a bastion-side
  forced-command run, use a local execution path for snapshot, age-identity
  injection, deploy, and rollback instead of self-SSH.
- When building a proxy chain, drop any leading `proxyJump` hops that resolve to
  the current host before assembling SSH proxy wrappers, but keep the full
  configured chain available as a retry path when the flattened direct route is
  not actually reachable from the current runtime context.
- Keep managed-file injection on one shared target-transport path instead of
  separate local and remote implementations.

## Implementation

- `pkgs/nixbot/nixbot.sh` now tracks `PREP_DEPLOY_LOCAL_EXEC` in the prepared
  deploy context.
- `prepare_deploy_context()`:
  - recognizes bastion-side self-target deploys
  - returns a local execution context for them
  - normalizes `proxyJump` through `resolve_effective_proxy_chain()`
  - retries with the full configured proxy chain when a flattened direct probe
    to the primary deploy target fails, independent of whether bootstrap and
    deploy users differ
- Current-host matching resolves and compares both aliases and addresses.
- Self-target local execution is gated to forced-command ingress so normal
  operator-initiated local runs still use the configured deploy SSH user/key.
- `resolve_effective_proxy_chain()` is the single canonical proxy-hop resolver:
  it walks the configured hop list once, trims leading local/self hops, and
  emits the exact remaining target addresses for downstream SSH setup.
- The SSH-context setup and ProxyCommand builder both consume the trimmed
  effective proxy chain directly, so removed leading local hops cannot be
  reintroduced while rebuilding wrappers.
- Bastion-side proxy flattening is therefore opportunistic rather than blind:
  direct guest access is preferred when it works, and the original proxy path is
  restored automatically when the bastion runtime cannot route directly to the
  guest.
- Generated proxy wrapper scripts format SSH `-W host:port` targets with
  IPv6-safe bracket syntax, so flattened or restored proxy chains work for both
  IPv4 and IPv6 hop/target addresses.
- Managed file installs, rollback, and `nixos-rebuild-ng` now all consume one
  shared target sudo policy. That policy distinguishes password prompting from
  SSH TTY allocation instead of treating them as the same decision.
- Host phases (`snapshot`, `deploy`, `rollback`) branch on the prepared local
  execution flag instead of assuming every target is remote.

## Operational Effect

- Bastion-triggered runs no longer depend on fresh SSH connectivity back into
  the bastion host after switching that same host.
- Guests behind the bastion can be reached directly from the bastion during the
  same run, instead of proxying back through the bastion's own ingress path,
  when that direct path is actually routable from the active runtime context.
- Bastion-side CI still preserves guest reachability when the guest network is
  only reachable through the bastion's own SSH service, because `nixbot` retries
  with the original configured proxy chain before falling back to bootstrap
  injection.
- This only applies to runs started after the patched `nixbot` is installed on
  the bastion. A currently running bastion-triggered process stays pinned to the
  already-installed wrapper for the duration of that run.

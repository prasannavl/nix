# Nixbot Proxy Hop Auth And Staged Overlay (2026-03)

## Scope

Durable decisions and fixes for bastion-trigger argument forwarding, multi-hop
SSH proxy authentication, and staged-worktree overlays.

## Decisions

- Bastion-trigger forwarding remains intentionally restrictive. Only the
  bastion-safe subset of request arguments is forwarded to the remote wrapper,
  so bastion-side execution stays anchored to repo-local defaults and committed
  configuration instead of inheriting arbitrary local deploy-shaping flags.
- This restriction should be documented inline at the forwarding site so future
  reviews do not misclassify it as an accidental omission.

## Fixes

- Proxy wrapper scripts must preserve each hop's configured SSH user and
  resolved identity file instead of collapsing hops to bare target addresses.
  The outer deploy key on the final SSH command is not enough for intermediate
  `ProxyCommand` connections.
- Proxy-wrapper setup must initialize the shared temp workspace even for dry
  runs, because proxied dry-run requests still build wrapper scripts and should
  print the deploy command instead of crashing on an uninitialized SSH temp
  directory.
- `resolve_proxy_chain()` now carries per-hop metadata needed by the wrapper
  builder: hop node, target, connect target, and key path.
- Per-hop proxy key paths follow normal host-config key rules; they must not
  inherit the explicit `--ssh-key` override's `.age`-only validation.
- `--dirty-staged` worktree overlays must fail closed. If the cached diff cannot
  be applied cleanly, or a staged added file cannot be materialized into the
  worktree, the run must abort instead of proceeding with a partially overlaid
  tree.

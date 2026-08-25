# `pvl-vlab-1` cache DNS relay failure

## Incident

Nixbot run `3QAkzu`, started August 25, 2026 at `22:51:34 +0800`, built the new
`pvl-vlab-1` system successfully in six seconds but failed its deploy phase
after 52 seconds. Retained diagnostics are under `/var/tmp/nixbot/diag-3QAkzu`.

The target-side cache handoff attempted this exact path:

```text
/nix/store/0yzf2503gij0w9v645k1f01vv2vzkx5i-nixos-system-pvl-vlab-1-lxc-26.05.20260823.a3b9886
```

Every attempt failed before activation while reading the configured cache
metadata:

```text
http://pvl-x2:5000/nix-cache-info
Could not resolve hostname (6) Could not resolve host: pvl-x2
```

Nix performed its own five download attempts for each command. Nixbot then
repeated the whole target-side copy three times with two- and four-second outer
backoffs. DNS remained unavailable, so repetition could not converge.

## Confirmed boundary

The failure is not the earlier `pvl-x2` self-cache negative-narinfo race:

- `pvl-x2` deployed successfully in the same run.
- `pvl-vlab-1` is a distinct store and failed on cache endpoint DNS before any
  closure lookup.
- The operator resolved `pvl-x2` and fetched the exact system path's signed
  `pvl-1` narinfo successfully from the same cache after the run.
- Inventory reaches `pvl-vlab-1` at `10.10.20.30` through
  `proxyJump = "pvl-x2"`; that operator SSH route does not give the guest DNS
  access to the operator-facing hostname.

The snapshot phase recorded the unchanged old generation:

```text
/nix/store/wmn2pxnk4grcqwgrwrs50z3zraaby3mh-nixos-system-pvl-vlab-1-lxc-26.05.20260822.a9e6d84
```

Nixbot never marked activation as started, so it correctly skipped rollback.

## Design defect

`--build-host-deploy-mode auto` previously selected one effective mode solely
from whether the build host matched the configured cache owner. It did not
consider the deploy target. A matching builder/cache identity therefore made
every distinct target execute `nix copy --from <cache-url>` locally, even when
that target was reachable only through an operator proxy and could not resolve
the cache URL.

A successful copy on another target is not proof of cache reachability. If the
exact closure is already valid in that target store, `nix copy` can finish
without requesting `nix-cache-info`.

## Resolution

Automatic distribution is now per-target:

- Same canonical build-host and target resources validate the already-present
  closure locally and offline.
- Targets declared with `proxyJump` or `proxyCommand` relay the signed cache
  path through the operator immediately.
- Direct targets keep the efficient target-side cache copy. On a non-interrupt
  failure, `auto` falls back once to the signed local-client relay.
- The first direct target-side command does not receive Nixbot's outer command
  retries before fallback. Nix still owns its internal download retries and SSH
  transport failures retain the prepared transport retry policy.
- Explicit `cache` remains strict and outer-retried. Explicit `local-copy`
  remains an unconditional relay.

Both distinct-store paths source the configured signed build-host cache and use
the target's temporary trusted-public-key bridge. The fallback changes only the
transport. It does not weaken signature enforcement, copy from an unverified
builder store, or permit activation after a failed distribution.

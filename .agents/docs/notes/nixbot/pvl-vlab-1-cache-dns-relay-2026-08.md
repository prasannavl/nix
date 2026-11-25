# `pvl-vlab-1` cache DNS relay failure

## Current native policy (2026-11)

- `auto`: keep same-store verification and target-first pull when the builder
  owns the cache. Only a final Nix DNS, connection or timeout error for that
  cache can switch routes. Retry chatter, SSH errors, missing paths, TLS,
  signature and hash failures are not evidence for a different route.
- Prefer the existing workstation relay when it works. If its HTTP(S) source
  also fails to connect, use the exact declared registry owner
  (`registries.nix`, or legacy `buildCache`) and its primary SSH route. An
  unmatched host or URL override, or a local owner, grants no additional
  fallback. Retained handoffs gain no builder access. Explicit modes are
  unchanged.
- Each active owner relay has a foreground SSH process and a private Unix SOCKS
  socket, not a shared daemon or listening TCP port. Nix keeps the original
  cache URL, TLS identity and signature checks. The destination uses its normal
  Nix SSH options and any HTTP-based jump helper retains its original proxy
  environment. Automatic route attempts bound connection setup, not closure
  transfer time. See `pkgs/tools/abird-host-manager/tests/cache-relay-smoke.sh`
  for an opt-in isolated OpenSSH, HTTP(S) and signed-Nix-cache check.

### Moving a cache without stranding old generations

1. While the old publisher is still reachable, add the new cache route to the
   gateway and consumers **alongside** the old one. Deploy that routing change
   first.
2. From the running consumer, verify the route and fetch `nix-cache-info` and an
   expected signed path from the new publisher. A candidate evaluation or a
   cache-owner-local probe is not consumer reachability.
3. Switch the registry URL and verify a normal acquisition. Retire the old route
   only after consumers and required rollback generations no longer need it. Do
   not widen the VPN or firewall to compensate for rollout order.

The sections below record earlier implementations and incidents.

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

The first repair selected the relay immediately for targets with `proxyJump` or
`proxyCommand`. A later Abird incident demonstrated the inverse reachability
case: the target could fetch its cache while the operator could not resolve it.
Proxy metadata therefore cannot choose the cache client.

The final shared distribution order is:

- Same canonical build-host and target resources validate the already-present
  closure locally and offline.
- Every distinct-store target first uses the target-side cache copy. On a
  non-interrupt failure, `auto` falls back once to the signed local-client
  relay.
- The first target-side command does not receive Nixbot's outer command retries
  before fallback. Nix still owns its internal download retries and SSH
  transport failures retain the prepared transport retry policy.
- Explicit `cache` remains strict and outer-retried. Explicit `local-copy`
  remains an unconditional relay for a remote target; a local self-target
  imports directly because both contexts use the local Nix client.

Both distinct-store paths source the configured signed build-host cache and use
the target's temporary trusted-public-key bridge. The fallback changes only the
transport. It does not weaken signature enforcement, copy from an unverified
builder store, or permit activation after a failed distribution.

## Rust parity correction, September 2026

Native fleet run `4c4ea46816a544c1be95ba8dca1fcbd9` reproduced the same
target-side DNS failure. Its local client successfully fetched the complete
34-path closure, but the Rust fallback then rejected `pvl-vlab-1` solely because
the target uses `proxyJump = "pvl-x2"`. This was an implementation gap rather
than a new network failure.

The native relay now mirrors the final Bash design: one signed
`nix copy --from <cache> --to <target>` runs with `NIX_SSHOPTS` derived from the
complete prepared target route. Connection multiplexing is disabled for this
store operation, IPv6 authorities are bracketed, and only classified transport
loss receives bounded retry. Proxy-chain and explicit-`proxyCommand` tests cover
the regression. Per-target diagnostic labels prevent concurrent relay logs from
colliding.

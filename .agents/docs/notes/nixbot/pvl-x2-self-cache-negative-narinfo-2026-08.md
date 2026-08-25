# `pvl-x2` self-cache negative narinfo failure

## Incident

Nixbot run `GboCmY`, started August 25, 2026 at `21:16:17 +0800`, built the new
`pvl-x2` system successfully but failed its deploy phase after 17 seconds. The
retained diagnostics are under `/var/tmp/nixbot/diag-GboCmY`.

The deploy failed before activation. Nixbot ran the target-side handoff from the
configured `pvl-x2` Harmonia cache into the `pvl-x2` target store:

```text
Copying built closure to pvl-x2 from pvl-x2 cache:
/nix/store/k3y82704qr3mr73185yk53gkcr67bjn5-nixos-system-pvl-x2-26.05.20260823.a3b9886
error: path '/nix/store/fvg5anm83bk1d73pb9vakf6rd3yfqy4k-abird-host-agent-systemctl' is not valid
```

The same deterministic error exhausted all three cache-copy attempts after two-
and four-second backoffs. The ignored local evaluation-cache SQLite busy warning
was unrelated.

Run `rsZcMk`, started at `22:01:38 +0800`, reproduced the same failure against
the already-built system path. Its build completed in four seconds, but the same
closure member failed all three target-side copy attempts. This recurrence
confirmed that retrying the cache copy was not a convergence mechanism for this
topology.

## Store and cache evidence

The missing-path message did not mean that the remote build omitted or lost the
artifact:

- `pvl-x2` registered `fvg5anm...-abird-host-agent-systemctl` at `21:19:11`,
  before the cache-copy failure at `21:23:41` through `21:23:49`.
- The completed `k3y827...` system output was registered at `21:23:03`.
- Both paths remained valid in the builder/target store with their original
  creation times; neither was deleted and restored.
- Harmonia returned signed HTTP 200 narinfo for both paths, and recursive path
  discovery through `http://pvl-x2:5000` succeeded after the run.
- Automatic Nix free-space collection is disabled (`min-free = 0`), and the
  scheduled `nix-gc.timer` had last run on August 24. Garbage collection did not
  explain this incident.

The confirmed immediate cause is therefore a false-negative binary-cache path
lookup during the target-side copy, not a build failure or absent builder-store
closure.

## Negative narinfo mechanism

The effective host configuration makes `pvl-x2` all three of the following:

- the default remote builder;
- the owner of `http://pvl-x2:5000`;
- the deploy target for the `pvl-x2` system.

The remote build uses `nix build --store ssh-ng://... --no-link`. Nix checks new
dependency outputs against configured substituters before realizing them. On
this host, the substituter list includes its own Harmonia endpoint. A miss for a
new output can therefore be recorded immediately before the builder creates that
same output.

The effective `narinfo-cache-negative-ttl` is 3,600 seconds. The later
target-side `nix copy --from http://pvl-x2:5000` runs on the same physical host
and can reuse that stale negative cache result. Nixbot's bounded two- and
four-second retry delays cannot outlive a one-hour negative entry.

This cache-entry sequence is the evidence-backed explanation for why Nix
reported the already-valid `fvg5anm...` path as invalid. The retained run does
not include the root binary-cache SQLite database or an HTTP access log, so the
specific negative row is inferred from the path-registration timeline, the
self-substituter topology, the configured TTL, and the repeated false-negative
result.

## Deployment boundary and current state

Nixbot did not reach pre-activation Podman image pulls, mark activation as
started, run `switch-to-configuration`, or start health settlement. It therefore
did not need or attempt rollback.

The target retained both `/run/current-system` and the persistent system profile
at the snapshotted old generation:

```text
/nix/store/m1sam24sfkz06ldf48bfy2lb3ycfs3gi-nixos-system-pvl-x2-26.05.20260822.a9e6d84
```

Read-only validation after the run showed system state `running`, zero failed
system units, and no retained activation unit for this run.

## Resolution

Nixbot now resolves the build host and deploy node to canonical inventory
resources using each endpoint's `resourceId`, with the inventory key as the
fallback. When both roles resolve to the same resource, it does not route the
deployment through that store's HTTP cache view.

The same-store path runs this validation over the already-prepared target
transport:

```text
nix --offline --quiet store verify \
  --no-contents --no-trust --recursive <system-path>
```

This proves that the exact root and its full registered closure are present
without consulting any substituter, rehashing a large system closure, or
requiring a cache signature for locally built paths. A missing closure member
still fails before activation. Distinct stores retain the signed target-side
cache copy or local-client relay selected by the deploy mode.

The remote-build deployment paths now share one distribution decision and one
activation sequence, so explicit `local-copy` cannot accidentally relay a store
back into itself. Focused regression coverage proves canonical alias matching,
fail-closed handling for different resources that share an address, the exact
offline recursive validation command, and routing for same-store, cache, and
relay cases.

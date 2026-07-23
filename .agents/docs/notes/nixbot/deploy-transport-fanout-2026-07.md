# Nixbot Deploy Transport Fan-Out, 2026-07

The default deploy wave concurrency is 8. That value was chosen intentionally as
the normal balance between throughput and remote SSH/Nix daemon pressure for
Abird waves. Do not lower the default to hide service-level or reconciler-level
wedges; fix those root causes instead.

Use `--deploy-jobs` for intentional operator overrides. If high fan-out exposes
SSH banner, remote-store, or activation transport loss, keep the deploy
transport resilient while preserving the default concurrency.

The global value is the outer ceiling. Nixbot also accepts a uniform per-domain
ceiling:

```text
--deploy-jobs-per-domain 2
```

`config.deployJobsPerDomain` and `NIXBOT_JOBS_PER_DOMAIN` expose the same
setting. When none is set, it defaults to the resolved `--deploy-jobs` value and
adds no narrower admission boundary.

A host's domain is inferred by following `parent` to the topmost ancestor. The
root and every descendant share that root-name domain, even when the parent was
included only as a dependency or group exclusions remove it from the selected
host list. Independent roots have independent domains. `deps` and `after` remain
ordering-only and never change capacity ownership.

Nixbot keeps dependency levels topology-only, then deterministically splits each
deploy level into capacity-bounded subwaves before parent readiness, copy,
preparation, or activation. Rollback uses the same subwaves in reverse.
Build-plan evaluation and builds remain independently parallel, as does the
native systemd service graph inside each guest.

Parent inference is intentionally narrower than a general physical-domain
registry. Two distinct root parents that happen to share one physical machine
remain separate domains, so their mutating group deploys must remain sequential.
If cross-root deploys become necessary, that requires an explicit physical
capacity model rather than deriving one from logical dependencies.

Deploy `vBfqbQ` supplied the physical-host evidence for this distinction. Ten
Gondor builds completed, and the parent deployed in 17 seconds, but the first
six-guest child wave drove their common `pvl-x2` Incus host to load 1409, 299
D-state tasks, 99% I/O pressure, and severe memory pressure with no swap. SSH
authentication stalled long enough for the default `MaxStartups` threshold to
drop connection 10. Tictactoe then failed before copy or activation, and
fail-fast canceled the remaining pre-activation jobs. Once the wave ended, all
guests, managed targets, declared containers, and public origins were healthy.
This was a shared admission/capacity failure, not a service failure.

Transport retry amplified the wave because bounded commands used
`timeout --foreground`. That mode timed out only the direct SSH process and left
its generated `ssh -W` ProxyCommand descendants alive; retries accumulated more
unauthenticated first-hop connections. Bounded non-TTY SSH must stay in
`timeout`'s owned process group. Clearing a failed ControlMaster must retire the
exact process tree before unlinking its socket, and every generated proxy hop
must carry the same connection and keepalive bounds as the outer transport.

Do not respond by raising `MaxStartups`, lengthening SSH timeouts, globally
serializing deploys, or lowering the default eight-job cross-domain ceiling.
Those changes either admit more work to an exhausted host or penalize unrelated
parents. Guest resource envelopes, swap policy, and placing another stack on the
unused physical NVMe remain separate capacity/isolation work; the deploy
scheduler must still respect the failure domain even after those improvements.

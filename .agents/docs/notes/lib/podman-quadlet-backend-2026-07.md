# Podman Quadlet Backend

## Decision

`services.podman-compose` supports an explicit `backend = "compose" | "quadlet"`
at stack or instance scope. Compose remains the default and no existing workload
is migrated automatically.

Both backends keep the same public lifecycle graph:

```text
<user>-managed.target
  Wants -> <name>-ready.target
              Requires -> <name>-verify.service
                            Requires -> <name>.service
```

The public `<name>.service` stays the bounded, repo-owned lifecycle owner. For a
Quadlet instance it starts and stops one private generated container unit while
holding the same per-user rootless mutation transaction used by Compose. The
private unit has no install membership and `Restart=no`; it is an implementation
detail rather than a second lifecycle or restart owner.

## Phase-One Conversion Contract

Quadlet is deliberately strict:

- structured sources with exactly one service
- short-string ports
- primitive argv lists for `command` and `entrypoint`
- primitive environment values or `KEY=VALUE` strings
- bind mounts only; relative sources and env files become absolute paths under
  the staged working directory
- optional container name, user, and working directory
- pre-start/bootstrap and pre-stop hooks through the shared wrapper

Evaluation rejects unsupported top-level keys, multi-service sources, Compose
dependencies, healthchecks, networks, named or anonymous volumes, string shell
commands, signal reload, adoption, custom subnets, provider-specific compose
arguments, `longRunning = false`, unmatched secret target-service names, and
removal policies other than `delete`. There is no silent Compose fallback.

## Runtime and Health Guarantees

- The wrapper commits start only after both the private unit and the exact
  labeled container are running.
- Before touching a private unit, the adapter verifies both its declared
  `SourcePath` and its fragment under the user generator directories. A
  same-named hand-written or differently generated unit is not mutated.
- Failed cleanup rolls back cleanly only after fresh unit/container absence is
  proven. Podman query errors are indeterminate and leave the per-user runtime
  dirty, blocking later mutations.
- Provider changes are clean-only handoffs. Staging preserves the last applied
  backend; start and preflight refuse Compose-to-Quadlet or Quadlet-to-Compose
  admission while the prior provider still owns a unit or container. Only a
  successful start commits the new provider identity.
- Images use the existing deploy preparation plan. Generated Quadlet units use
  `Pull=never`, preventing hidden pull ownership.
- Verification honors an image-defined Podman healthcheck: `starting` is polled
  within the existing readiness deadline and `unhealthy` fails only that
  instance's verifier.
- Health reads one Podman inventory snapshot per user and matches stable
  repo-owned backend, instance, working-directory, and service labels.
- `podman-composectl expected-units` includes private runtime units, while the
  public wrapper/main/ready interface remains the operator surface.
- A failed verifier remains leaf-local because the managed root weakly wants
  each ready target; it does not require every child.

## Origin-Probe Transport

Automatic local origin probes are backend-neutral and derive `http` versus
`https` from `exposedPorts.http.upstreamProtocol`. HTTPS probes use declared
host/SNI metadata with loopback resolution and tolerate local certificate
verification because they are liveness probes; an explicit `verifyCommand`
remains the strict semantic/trust escape hatch. Generated probes retry bounded
transport failures and 5xx responses within the declared readiness budget, but
explicit commands are not implicitly retried.

This rule fixed the 2026-07-15 Kanidm false failure where cleartext HTTP was
sent to its ready TLS listener. The same latent declaration issue was corrected
for VictoriaMetrics and VictoriaTraces.

## Validation Boundary

The module test runs the exact evaluated `.container` artifact through Podman's
real Quadlet generator. Conversion tests cover accepted and rejected shapes;
helper tests cover clean commit, proven rollback, indeterminate cleanup,
generated-unit ownership, and backend transition admission across staging; the
existing lifecycle VM proves verifier failure isolation and explicit
managed-root drain/resume; and a focused VM proves that user-manager reload adds
and removes the generated private unit without install membership. Real workload
migration still requires a separate service-specific review.

Compose compatibility is kept deliberately narrow: existing Compose metadata
remains schema v11 and uses the Compose-only helper package, while Quadlet uses
schema v12 and the backend-aware helper. Generated services call stable helper
names from `/etc/podman-compose/helpers`, so implementation-only package churn
no longer changes every unit. The first transition from older store-qualified
commands is protected by the pre-switch sequential drain. Selecting Quadlet
changes the stable helper name and still performs an explicit, clean provider
handoff; selecting no backend does not silently migrate a service.

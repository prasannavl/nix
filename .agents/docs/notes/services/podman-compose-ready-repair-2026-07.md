# Podman Compose Readiness and Runtime Containment 2026-07

The generated Podman lifecycle graph has one public managed root per service
user. The root weakly wants each instance ready target, while each leaf owns its
full readiness chain:

```text
<user>-managed.target
  Wants -> <name>-ready.target
              Requires -> <name>-verify.service
                            Requires -> <name>.service
```

This keeps a failed verifier leaf-local instead of making one unhealthy instance
cancel unrelated ready services. The main service is a bounded repo-owned
lifecycle wrapper. Compose and Quadlet provider units remain private
implementation details.

`startConcurrency` replaces the older `startParallelism` surface. It defaults to
four per managed user, accepts `-1` for unlimited concurrency, and spans the
whole start-through-ready transaction. `startPriority` provides a deterministic
tie-breaker but never overrides declared dependency edges.

Rootless Podman mutation is serialized per service user. Runtime preflight,
image preparation, provider mutations, rollback, and evidence-scoped network
repair share the same transaction boundary. Application verification is
read-only and runs after the provider transaction commits. A provider start is
never terminated and replayed merely because dependency health or DNS is still
settling.

Readiness checks declared services, container state and health, and an optional
`verifyCommand`. When `verifyCommand` is empty and `exposedPorts.http` declares
an HTTP or HTTPS upstream protocol, the module generates a bounded local origin
probe. TLS probes use the declared host metadata and loopback resolution.

Inline YAML local images retain a generated closure root. An authoring-time
`image: nix-store:${package}` reference is rewritten to a stable runtime tag and
the image tar remains reachable on fresh deploy targets even if parsing the YAML
would otherwise lose Nix string context.

Quadlet is opt-in and supports only the strict, single-service conversion
surface documented in the Podman Quadlet backend note. Existing Compose
instances are not migrated automatically, and provider changes require a
proven-clean handoff.

## Converge readiness before sampling health

The 2026-08-29 `gap3-rivendell` deploy exposed a health-ordering race after an
intentional cold Quadlet recreation. Zulip's first verifier exhausted its
service-owned budget. Nixbot sampled the failed verifier and inactive ready
target, then its expected-runtime query retried the verifier successfully. The
health result still reported the earlier sample, and starting the verifier
directly did not activate the declared ready target.

Expected-runtime convergence must therefore happen before expected-unit and
failed-unit sampling. For a declared Quadlet service it starts the registry's
explicit `readyUnit`, not a derived verifier name, after confirming the owning
main unit is active. This records successful convergence at the lifecycle
target. Held main units remain filtered before this operation, and a missing
`readyUnit` fails closed instead of guessing a unit name.

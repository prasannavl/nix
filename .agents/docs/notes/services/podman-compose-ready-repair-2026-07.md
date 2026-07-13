# Podman Compose Ready Repair 2026-07

The generated Podman Compose graph keeps readiness narrow:

```text
<name>.service -> <name>-verify.service -> <name>-ready.target
```

For services with `postStart`, the reconcile edge remains:

```text
<name>.service -> <name>-reconcile.service -> <name>-verify.service
```

`cmd_verify` remains the readiness command. It waits briefly for an active start
marker or systemd transition on the owning service to settle, then checks staged
files, runtime stamps, and compose state. If runtime state is stale or compose
state is unhealthy, verify may restart the owning user service once and then
re-check. If the second check fails, verify fails normally.

The ready target should require only the verify unit. Do not make ready targets
require the owning compose service directly; shared managed-ready targets fan
out per-service ready targets, and a direct ready-to-service requirement can
start every compose service in one systemd transaction. That bypasses the
bounded service-start path and can overload dense rootless Podman hosts.

Keep verify ordered after the owning service, but do not make verify require the
service directly. A direct verify-to-service requirement can fight the bounded
restart that verify performs when repairing stale runtime state.

The generated compose service, bootstrap, reconcile, and verify units use the
instance's `timeoutReadySeconds` as `TimeoutStartSec`. Verify exports a
transition wait derived from that budget, keeping a small reserve before
systemd's timeout so readiness failures are reported cleanly.

Set stack-level `timeoutReadySeconds` on dense hosts instead of scattering
service-specific timeout overrides. Individual unusually slow services can still
raise their own instance timeout next to the service declaration.

The timeout budget is not sufficient by itself. If native switching starts every
changed compose service at once, rootless Podman can be overloaded. The module
therefore emits per-user `After=` edges between auto-starting compose services
so at most `startParallelism` services for a service user enter their start
transaction at once. The default is four, matching the old reconciler's default.

Those throttle edges are dependency-level aware. Dependency levels are built
from intra-stack `dependsOn` / `wants` edges and explicit generated unit
references, then the `startParallelism` sliding window is applied only within a
level. Declaration order is only a tie-breaker inside one dependency level; it
must not create ordering cycles across provider/consumer relationships.

Inline YAML local images need an additional closure root. An authoring-time
`image: nix-store:${package}` string can be parsed from YAML in a way that keeps
the literal `/nix/store/...` path in helper metadata but loses Nix string
context for deployment. The module therefore preserves context while extracting
inline image refs and emits a generated `*-local-images` link farm referenced by
the service unit environment. That environment reference is what makes fresh
targets receive the image tar before `podman-compose-helper` tries to load it.

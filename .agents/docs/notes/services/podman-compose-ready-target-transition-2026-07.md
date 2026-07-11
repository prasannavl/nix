# Podman Compose Ready Target Transition 2026-07

`services.podman-compose` ready checks must not treat an active start marker or
a transitioning compose unit as ready. The helper should fail `cmd_verify` with
a clear "not ready" message while the compose unit is activating, deactivating,
or reloading, without running compose state inspection against partially staged
runtime state.

The durable invariant is:

- A compose unit in `activating`, `deactivating`, or `reloading` is not ready.
- An active `start-in-progress` marker is not ready.
- Active ready targets alone are not proof that browser-facing services have a
  reachable upstream.

Keep deploy health checks grounded in stable service state plus current compose
state, and let the service-owned ready timeout decide whether convergence is too
slow.

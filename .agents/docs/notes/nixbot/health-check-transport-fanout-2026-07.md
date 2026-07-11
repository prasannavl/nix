# Nixbot Health Check Transport Fan-Out 2026-07

Post-deploy health checks are transport-sensitive, but they may fan out through
the same bounded `--verify-jobs` budget as rollback snapshot verification. They
open fresh SSH sessions after hosts have just reloaded system and user units, so
keep this budget deliberate and bounded rather than tying health checks to
deploy fanout.

A health-check transport timeout is not proof of service failure. Do not let
unbounded parallel probes become the trigger for rolling back an otherwise
successful service reconciliation.

Podman Compose asynchronous workers may be accepted by the activation
transaction itself. Post-switch health checks are different: active start
workers mean the declared app is not settled yet, and a published route can
still have no upstream listener. Treat active workers as deployment work still
settling, use the service-owned `timeoutReadySeconds` health window, and fail
the deploy if they do not converge. Failed start-worker units are hard failures
and must remain visible to the normal failed-unit health path.

Interactive deploy console output may normalize high-volume activation,
closure-copy, agenix, and health-check rows for readability. Persisted host logs
must keep the raw unnormalized output.

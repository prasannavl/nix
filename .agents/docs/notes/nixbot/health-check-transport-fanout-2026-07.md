# Nixbot Health Check Transport Fan-Out 2026-07

Post-deploy health checks use the bounded `--verify-jobs` budget and fresh SSH
sessions after activation. A transport timeout is inconclusive; it is not by
itself proof that the candidate service graph failed.

Nixbot verifies every declared auto-start Podman instance against the generated
expected-runtime registry. One Podman inventory snapshot per managed user is
matched against expected backend, instance, working-directory, service, unit,
container state, and health labels. Missing, terminal, or unhealthy runtime is
reported independently from target-local origin probes.

`health=starting`, active user jobs, and active rootless mutation markers are
bounded settling evidence. Once no unit transition or mutation remains, an
unhealthy or missing declared runtime fails normally. Target-local verification
commands run in parallel after the shared inventory snapshot, so a proxy-wide
502 or unusable local origin cannot pass only because systemd units are active.

Deploy activation and health failure have different authority. A successful
activation on one host is not rolled back merely because a peer failed; rollback
is scoped to the hosts whose candidate state is actually invalid. Persistent
host logs retain raw output even when the interactive console normalizes noisy
health rows.

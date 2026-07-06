# Podman Compose Rollback Stale Containers, 2026-06

## Incident

During the 2026-06-23 `abird-dev-corp` deploy/rollback, Zulip showed high CPU
while `abird-zulip.service` and `podman ps` looked healthy. The real failure was
RabbitMQ:

- Zulip queue workers repeatedly logged `pika.exceptions.AMQPConnectionError`
  and `Connection refused` to `rabbitmq` / `10.89.3.4:5672`.
- `podman inspect zulip_rabbitmq_1` reported `running=true` with PID `46636`,
  but `/proc/46636` and the matching `conmon` PID were gone.
- `podman exec zulip_rabbitmq_1 ...` failed because the container was not really
  running, while the Podman network still mapped `rabbitmq` to `10.89.3.4`.
- The user unit remained active because the compose monitor and other containers
  were live; container-level dependency health was not represented in
  `systemctl --user --failed`.

The journal showed RabbitMQ started cleanly and accepted AMQP connections, then
rollback/user-service cleanup killed the compose container set:

- `nixbot-rollback-to-configuration-...` started at `19:48:33 +0800`.
- `podman-compose-helper` reported failed-start cleanup for `abird-zulip`.
- At `19:48:45 +0800`, systemd killed Zulip's remaining `conmon` processes,
  including the RabbitMQ `conmon`, with `SIGKILL`.
- Podman did not clean the RabbitMQ DB/network state, leaving a stale "Up"
  container entry with no process behind it.

## Diagnostic Pattern

When a rootless compose service is active but an app dependency is unreachable:

1. Check app logs for internal service connection failures, not only unit state.
2. Compare `podman inspect <container> .State.Pid/.State.ConmonPid` with
   `/proc/<pid>` existence.
3. Run `podman exec <container> true`; stale containers often fail here even
   when `podman ps` says `Up`.
4. Inspect the compose network mapping to see whether DNS still points at the
   stale container IP.
5. Check rollback/switch timing in the journal for `switch-to-configuration`,
   `podman-compose-helper`, `container died`, and `Killing process ... conmon`.

## Recovery Shape

For this stale-state failure, a plain health check is not sufficient. Recovery
needs a controlled compose/container reconciliation for the affected project so
Podman removes the stale container/network entry and recreates the missing
dependency. Do not treat CPU-heavy app workers as the root cause until the
dependency state is confirmed.

## Helper Fix

`lib/podman-compose/helper.sh` now performs a start-only preflight before
`podman compose up`: it lists existing containers for the compose working
directory, inspects running containers, and verifies that `.State.Pid` and the
reported `.State.ConmonPid` still exist under `/proc`. If a container is marked
running but either PID is missing, the start is promoted to
`podman compose up -d --remove-orphans --force-recreate`.

This intentionally runs only during `cmd_start`. The steady-state monitor still
uses compose state, so runtime policy remains unchanged except that a later
systemd/deploy start can repair stale Podman process state without requiring a
manual recreate tag bump.

## Start Idle Watchdog Follow-up

Start idle detection must not be more aggressive than the operational
activation threshold. A later `abird-corp` validation showed legitimate quiet
image-pull work inside `podman compose up` being killed every 45s, which turned
one slow start into repeated transitional failures for Forgejo, Outline,
Stalwart, and Superset. The helper start-idle watchdog now defaults to 120s so
it still catches silent wedges, but does not preempt normal quiet Podman work
below the threshold used for live deploy investigation.

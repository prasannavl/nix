# Nixbot Activation Transport Verification, 2026-07

Long NixOS activations must not share the prepared SSH control master. The
activation command is a single long-running `systemd-run --wait --pipe` session,
and heartbeat probes open additional SSH sessions while the host is reloading
units. If both use `ControlMaster=auto`, a single mux failure can surface as
`mux_client_request_session`, `Broken pipe`, or banner timeout even when the
remote activation keeps running and later switches `/run/current-system`.

Activation commands and activation heartbeat probes should use the prepared SSH
target with `ControlMaster=no` and `ControlPath=none`. Keep the normal prepared
transport for short setup/copy/probe work where connection reuse is useful.

Deploy activation failures caused by transport loss are inconclusive. Before
rolling back, verify the target state by reconnecting without the mux and
checking:

- `/run/current-system` resolves to the just-built system path, in which case
  the target reached the desired generation; still wait for the remote
  activation unit to settle with `Result=success` and `ExecMainStatus=0` before
  treating the deploy as complete. `ActiveState=inactive` only means the
  transient unit stopped; it does not mean its process succeeded.
- the remote activation unit settled inactive or failed while
  `/run/current-system` still points elsewhere, in which case the deploy really
  failed.
- the activation is still active, in which case keep waiting up to the remote
  activation timeout budget.
- either `/run/current-system` or the activation unit state is unknown, in which
  case keep waiting rather than retrying activation from an inconclusive sample.

Rollback already had target-state verification; deploy needs the same shape
because Incus guests can remain busy for several minutes after the SSH stream
breaks.

When reading `/run/current-system` during deploy or rollback verification,
normalize it to the underlying NixOS system store path before comparing it with
the target path. Do not treat an empty or missing activation-unit state as a
settled failure while the target generation is still changing; keep polling
until the unit is active/running, inactive, failed, or the verification timeout
expires.

The DIVdfq Abird incident showed the amplification hazard: a transport failure
was sampled as `unknown` before `/run/current-system` became readable as the new
generation, so nixbot retried activation while the first transient unit was
still settling. Rollback later switched to the same generation as the live
system. That same-generation rollback can still be useful: a failed switch can
leave stale runtime state, and re-running `switch-to-configuration` for the
recorded generation can repair partial activation side effects. Do not block
rollback only because the snapshot path matches `/run/current-system`; prevent
the earlier inconclusive deploy retry instead.

Health failure is narrower. It runs only after deploy activation has been
verified complete. If the pre-deploy snapshot and current system are the same
generation at that point, another activation is not a generation rollback; it
only replays service lifecycle side effects. Skip that matching-generation
activation for health-failure rollback, while retaining it for failed or
inconclusive deploy activation recovery.

The kJkSDn Abird incident exposed the corresponding false-positive hazard. The
generation symlink switched, but user-unit reconciliation exited 101 before the
user manager loaded and started the new graph. The transient activation unit was
inactive with a failed result, and generation-only recovery reported the deploy
as complete. All public services then returned 502. Transport recovery must
inspect the complete transient-unit outcome, not just `ActiveState` and the
generation symlink.

Successful transient units are garbage-collected, and `systemctl show` reports
synthetic success defaults for a missing unit. The activation runner therefore
writes an atomic result marker under `/run/nixbot/activation-results/` before it
exits. Transport recovery accepts success only from that marker or from an
explicitly loaded transient unit with a successful result and zero exit status.
Never infer success from `LoadState=not-found`.

The WmvwN6 incident showed that authority must gate failure and retry as well as
success. The first activation SSH connection failed, then recovery observed no
marker, `LoadState=not-found`, synthetic `ActiveState=inactive`, and the old
generation. That sample did not prove the activation had settled or that it had
never been admitted. A missing unit without its durable marker is always
inconclusive: it cannot complete the deploy, fail the activation, or authorize
another activation attempt.

Recovery samples the durable marker or loaded-unit outcome before reading
`/run/current-system`, in that order, through one bounded no-mux remote command.
This keeps the outcome and the generation in one coherent observation and avoids
combining a generation read from before activation completion with an outcome
read from after it.

Activation retry is admission-aware. SSH setup failures that prove the remote
command could not have run, such as connection-establishment or banner-exchange
failures, may start a fresh transient unit. A broken stream or other transport
loss after admission is ambiguous: verify the original unit and generation, but
never replay activation from a missing-unit sample.

The host-local activation `flock` belongs to the transient unit command, inside
`systemd-run`, rather than to the SSH-side `systemd-run --wait --pipe` client.
The unit therefore retains the lock if the transport process exits while
activation continues. Rollback uses the same placement and performs target-state
recovery only for transport-class failures. Signals and ordinary activation
failures preserve their original status without recovery overriding them.

The `LxNE05` activation showed that host-local execution alone does not isolate
the activation from its observer. `switch-to-configuration-ng` ignores SIGPIPE;
after the SSH reader disappeared, its final diagnostic write reached a closed
`systemd-run --pipe` stream and the Rust process panicked with status 101. The
normal user-activation failure status would have been 4, and the stream carried
the only detailed failure output.

Keep the direct `systemd-run --wait --pipe` path because it provides immediate,
ordered switch output. On the target, route the decoded activation through GNU
`tee --output-error=warn-nopipe` to an activation-specific log beside the result
marker, and derive the marker status from the activation process's pipeline slot
rather than from `tee`. The retained writer continues draining activation output
when the SSH reader closes, so the switch process never inherits the observer's
broken pipe. On authoritative failure after transport loss, replay a bounded
tail of that retained log before returning failure.

## User D-Bus is activation transport

Deploy `UAdvaK` failed only on Corp after its candidate service graph converged.
Its durable marker recorded `ExecMainStatus=4`, and the retained activation log
showed Peter's user activation failing to connect to `/run/user/1001/bus`. Live
readback found Peter declared with linger, logind retaining the user, the
runtime directory and socket pathname present, but `user@1001.service` dead and
no socket listener.

The preceding `OYyIRp` activation showed how that state was created. NixOS
classified `dbus-broker.service` for user reload, then
`switch-to-configuration-ng` asked the user manager to reload it through the
same D-Bus connection used to control and observe the rest of user activation.
The peer disconnected, later user jobs failed with protocol and closed-
connection errors, and Peter's manager exited. The next deploy inherited the
stale socket and could not begin that user's switch.

Treat the user D-Bus broker like SSH and the transient activation stream: it is
control-plane transport, not an ordinary workload unit. The shared host policy
forces `restartIfChanged = false` and `reloadIfChanged = false` on both
`dbus.service` and `dbus-broker.service`; broker changes take effect on a later
manager/session restart instead of mutating the connection that is using them.

Nixbot pre-switch admission uses `loginctl list-users`, the same inventory the
NixOS switch consumes. It starts a listed manager only when its
`user@UID.service` is inactive, then proves each user bus reachable before
copy/image preparation and before Podman drain. An active manager with an
unreachable bus is ambiguous and fails admission without an automatic restart,
so deployment never converts a control-plane problem into an unrequested
workload-wide user-manager restart.

## Proxy helpers are part of the SSH transaction

Deploy `vBfqbQ` failed before child activation while its common physical parent
was under severe I/O and memory pressure. Each bounded SSH retry terminated its
outer command but left generated `ssh -W` ProxyCommand descendants behind. The
orphaned helpers were adopted by the local user manager, and successive retries
multiplied unauthenticated first-hop sessions until the physical host's sshd
dropped new connections at `MaxStartups`.

Non-TTY bounded SSH therefore runs under the normal process-group-owning GNU
`timeout` mode. TTY commands already use their separate direct path and do not
need foreground timeout semantics. A retry that clears a per-target
ControlMaster first identifies processes with the exact `ControlPath`,
terminates their trees, and only then removes the socket. Generated proxy-hop
SSH also carries batch mode, one connection attempt, connect timeout, and
server-alive bounds. A transport attempt and every process it created now share
one lifetime; retries cannot amplify a failed route.

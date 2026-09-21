# Nixbot build-host route and known-hosts failure

## Incident

On September 21, 2026, three local
`nixbot deploy --dirty-staged
--skip-global-lock` attempts from `pvl-l5`
repeatedly lost the remote build-host transport to `pvl-x2`. The visible errors
included:

- `Connection timed out` to `192.168.1.1:22`;
- `No ED25519 host key is known for 192.168.1.1` during lease reacquisition;
- `Nix daemon disconnected unexpectedly` while copying a derivation to the
  `ssh-ng` build store.

The first two runs retained diagnostics as `diag-j0jhaO` and `diag-61gJOh`. The
third run, `diag-XGtfh4`, built `pvl-a1` successfully but failed while building
`pvl-l5`. No host reached activation in these attempts.

## Effective transport differs from interactive SSH

The ignored local file `hosts/nixbot.override.nix` overrides the committed
`pvl-x2` inventory target with `192.168.1.1`. Nixbot evaluates that override by
default and deliberately passes `-F /dev/null`, an isolated per-run
`UserKnownHostsFile`, and `StrictHostKeyChecking=yes`. It therefore does not use
the operator's SSH host stanza.

Interactive `ssh pvl-x2` had a different effective configuration:

- `HostName 100.100.1.1`;
- `HostKeyAlias pvl-x2`;
- the operator's persistent `~/.ssh/known_hosts`;
- a local command identifying the route as Tailscale.

An interactive SSH success over `100.100.1.1` therefore does not validate
Nixbot's direct LAN route or its isolated trust file.

## Direct SSH failure, not a blanket LAN failure

Read-only probes during the incident established a transient failure affecting
the direct address and direct SSH path:

- an 8-packet probe to `192.168.1.1` lost 62.5 percent;
- a later 20-packet probe lost 35 percent, with received replies delayed by
  roughly 1.8 to 3.6 seconds;
- the same 20-packet probe to `100.100.1.1` lost no packets and completed at
  roughly 104 to 185 milliseconds.

Those measurements do not prove that the physical LAN was generally broken.
`tailscale ping` reported `pvl-x2` as directly reachable through
`192.168.1.1:41641`, so the successful tailnet path was itself carrying
WireGuard UDP over the same LAN. Direct ICMP, direct TCP/22, and Tailscale's UDP
tunnel are distinct flows with different endpoint, retry, and migration
behavior.

The operator SSH configuration reflects that distinction. Its `Match exec`
clause performs a one-second fingerprinted `ssh-keyscan` of `192.168.1.1`. It
selects the LAN address only when that probe succeeds and otherwise falls back
to `100.100.1.1`. The operator command selected Tailscale during the incident,
but the same check selected LAN after recovery.

The `pvl-x2` journal corroborated transport loss from `192.168.10.2`. It showed
many connections closing before authentication, successful `nixbot` sessions
followed by a client-side reset, and successful Nix daemon connection
acceptance. It did not show a matching Nix daemon crash or a NetworkManager
restart on `pvl-x2`.

`Nix daemon disconnected unexpectedly` was consequently Nix's generic report for
a lost `ssh-ng` connection, not evidence that the remote daemon crashed.
Tailscale remained usable because it could maintain a separate UDP/WireGuard
flow and change underlay endpoints, while direct SSH was pinned to one TCP flow
and address. The host journals showed Tailscale considering both LAN IPv4 and
global IPv6 endpoints during this period.

Later checks showed that the condition had cleared: five one-second LAN probes
had no loss, `tailscale ping` used `192.168.1.1:41641` in 13 milliseconds, and
three authenticated SSH connections through each address all completed in
roughly 130 to 154 milliseconds. Interface counters showed no persistent link
error sufficient to identify a physical fault. The exact transient network cause
was therefore not established.

This incident differs from the earlier local self-deploy race: transport was
already failing during build-host lease acquisition and build copy, before any
activation could restart the controller network.

## OpenSSH scan penalties

`pvl-x2` runs OpenSSH 10.5 without an explicit `PerSourcePenalties` override, so
the upstream defaults apply. A connection that closes without attempting
authentication accrues a one-second `noauth` penalty; enforcement begins once 15
seconds are accumulated. The manual explicitly warns that this can penalize
legitimate `ssh-keyscan` use.

The server journal recorded many deferred `noauth` penalties for LAN source
`192.168.10.2`, matching Nixbot's repeated scans. The operator's dynamic LAN
probe also uses `ssh-keyscan` and contributes the same kind of event.

This is an amplification risk, not a complete explanation for the incident: the
retained journal showed deferred penalties but not a confirmed enforced refusal,
and penalties do not terminate already-established connections. It does explain
why repeated live scanning is the wrong trust and liveness mechanism and can
make a transient direct-SSH problem self-reinforcing.

## Secondary known-hosts lifecycle defect

Nixbot amplified the route failure into misleading host-verification errors:

1. `prepare_host_ssh_contexts` calls `ensure_known_hosts_file` each time a host
   context is prepared.
2. `ensure_known_hosts_file` truncates the node's shared per-run file even when
   another live build-host session is using it.
3. `ensure_known_host` tries a five-second live `ssh-keyscan`, suppresses its
   diagnostics, and ignores failure.
4. Direct connections then use the possibly empty file with
   `StrictHostKeyChecking=yes`.
5. Build-host lease and store operations repeatedly prepare the same `pvl-x2`
   context, so a later failed scan can erase a key acquired earlier in the run.

During the third attempt, the active `known_hosts.pvl-x2_` file was only 38
bytes and `ssh-keygen -F 192.168.1.1` found no usable entry. Existing sessions
could continue with keys already loaded, while new lease or copy connections
failed with `No ED25519 host key is known`.

The message means the isolated temporary trust file no longer contained a usable
key. It does not indicate a server host-key mismatch or rotation.

## Repair boundaries

The immediate operational reliability option is to stop hard-pinning the direct
address when failover is desired: remove or change the ignored local override,
or use `--no-override` for a run that should use the committed `pvl-x2` target.
This chooses the MagicDNS tailnet address rather than reproducing the operator
SSH config's dynamic LAN probe. Confirm the complete nested proxy route before a
fleet deployment.

Pinning an authenticated `knownHosts` entry can prevent live key discovery from
failing, but it does not repair the lossy `192.168.1.1` transport.

The durable Nixbot repair should make per-node known-host initialization
idempotent and concurrency-safe, preserve already acquired keys, and fail with a
clear key-discovery error when a direct strict target has no usable key. Tests
should cover repeated and concurrent build-host context preparation plus a
failed later key scan. Prefer a configured authenticated host-key pin over
repeated live scans. Do not weaken strict host-key checking or OpenSSH's
per-source protection to conceal the lifecycle bug.

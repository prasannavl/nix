# Nixbot cache-owner race and pvl-vk-1 dotfiles failure

## Incident

Run `NlBSxs` started on September 7, 2026 at `11:47:34 +0800`. The retained
diagnostics are in `/var/tmp/nixbot/diag-NlBSxs`.

The final summary reported two different outcomes:

- `pvl-l5` was built but not deployed. Its deploy phase returned status 1 before
  activation.
- `pvl-vk-1` copied its closure and entered activation, but activation returned
  status 4. Its automatic rollback returned status 0 and restored
  `g84yhgvwlays4hrxsjz387mfxpyb6ahk`.

## pvl-l5 cache-owner race

`pvl-l5` and the cache owner, `pvl-x2`, were independent level-zero hosts, so
their deploy jobs ran concurrently. Cache ownership is not represented as a
deploy-graph predecessor. The evaluated projection dependencies were exactly
`{"pvl-x2":[]}`. The inventory declared no `parent`, `deps`, or `after` edge for
`pvl-a1`, `pvl-l5`, or `pvl-x2`, so those three physical hosts formed wave 0.
The ancestry edges then formed wave 1 (`pvl-vlab`, `pvl-vlab-1`) and wave 2
(`pvl-vk`, `pvl-vk-1`).

The `controller`, `transferBroker`, builder, and Nix registry cache-owner roles
all point to `pvl-x2`, but they configure orchestration and transfer behavior;
none currently creates a deployment predecessor. The virtual-host ancestry
ordering therefore worked, while the independent `pvl-l5` cache consumer still
raced the cache owner's activation.

The retained logs and journals align exactly:

- At `11:51:47`, `pvl-l5` began a target-side `nix copy` from
  `http://pvl-x2:5000`.
- At `11:51:50`, `pvl-x2` began activation.
- At `11:51:51.072`, `pvl-x2` stopped `harmonia.service`; Harmonia reported
  graceful shutdown with live connections at `11:51:51.076`.
- At `11:51:51.366`, `pvl-x2` stopped NetworkManager. Harmonia and its socket
  were fully stopped by `11:51:52.402`.
- The target-side copy ended at `11:51:51.227` with the misleading terminal
  symptom that the NVIDIA store path was not valid. The path is now present and
  signed in Harmonia; the contemporaneous Harmonia log proves that the copy
  connection was interrupted by cache shutdown.
- The fallback relay began during the outage. The local `pvl-l5` Tailscale log
  recorded TCP resets from `pvl-x2:5000`, and every bounded relay attempt ended
  before `11:52:09`.
- NetworkManager and the Harmonia socket did not return until `11:54:40`.

No `pvl-l5` activation was submitted. Its current system remained the saved
`lv6r5wxwr5ym162pb7n2wxpgg6ih2nxk` generation after the run.

The durable orchestration issue is a cache-owner activation racing closure
consumers. Retrying for a few seconds cannot cover an activation-length outage.
The general fix boundary is to finish required transfers before activating the
cache owner, or encode ordering that keeps the cache available for every
consumer. The same-store verification and target-side-to-local relay fallback do
not address this cross-job scheduling race.

## pvl-vk-1 activation failure

`pvl-vk-1` first failed to resolve `pvl-x2` from the target, then successfully
used the expected local relay and copied all 793 paths. Its failure occurred
later inside `switch-to-configuration`:

- Home Manager restarted `dotfiles-sync.service` at `12:00:54`.
- The service ran Git against `https://github.com/prasannavl/dotfiles.git/` and
  failed after 133.621 seconds because it could not connect to `github.com:443`.
- Home Manager reported that `dotfiles-sync.service` failed, then emitted
  `timed out waiting on channel` and exited status 1.
- `home-manager-pvl.service` therefore failed, causing `switch-to-configuration`
  to return status 4 at `12:03:08`.
- Automatic rollback began after the activation unit settled and restored the
  saved generation successfully.

The retained evidence proves the activation-blocking external Git dependency,
but does not prove the deeper reason that the guest's GitHub TCP connection was
unavailable. The guest acquired its expected DHCP address and gateway during the
switch. The old and attempted-new `10-eth0.network` and `resolved.conf` files
are byte-identical, and the generated nftables rules differ only in Nix store
references. GitHub DNS and HTTPS worked after rollback.

The retained user journal from August 15 through this incident shows the daily
and prior activation-time dotfiles syncs completing in about one second. This
was the only observed connection failure in that interval, supporting a
transient transport incident rather than a persistent dotfiles configuration
error.

## Earlier dotfiles hardening boundary

The April change moved Git synchronization out of the Home Manager DAG and into
a timer-driven user service. The June hardening changed the timer from
`OnUnitActiveSec` to `OnCalendar`, delayed its startup attempt, added a DNS
probe, and protected the existing `~/bin` path. Those changes let the timer
schedule another attempt after a failure; they did not make the service's Git
failure non-fatal.

The incident generation's script still used `set -eu`, called `wait_for_network`
and `sync_dotfiles` without a best-effort boundary, and exposed the script
directly as `ExecStart`. Its default Home Manager switch method also allowed
`sd-switch` to restart the service when the unit file changed.

In this run, `pvl-vk-1` booted at `11:58:42`, the timer became active at
`11:58:43`, and its `OnStartupSec=30s` event plus timer accuracy delay fired at
`12:00:53`, exactly as NixOS activation began. Home Manager found the sync
active while switching to a changed unit file, stopped it, restarted it, and
waited for the replacement. The replacement's Git failure therefore propagated
through Home Manager despite the earlier timer hardening.

A complete isolation needs both boundaries: external DNS/Git failures must be
best-effort so they do not leave a failed unit, and the periodic service should
use Home Manager's `X-SwitchMethod=keep-old` so an in-flight timer job is not
restarted and awaited during activation. Local ownership/invariant failures can
remain fatal and should not be hidden with a blanket success status.

Treat this as an external-network-sensitive Home Manager activation failure, not
a cache-copy failure.

## Repository repair

The repository repair applies both isolation boundaries:

- `dotfiles-sync.service` uses `X-SwitchMethod=keep-old`, so a Home Manager
  switch leaves an in-flight timer job alone rather than restarting and awaiting
  it.
- The existing five-attempt DNS wait precedes a bounded 60-second Git fetch or
  clone. DNS or remote Git failure logs a warning and returns success so the
  timer can retry later. Existing checkouts remain usable and still restore the
  editable `~/bin` link.
- Local ownership conflicts remain fatal. An existing non-Git `~/dotfiles` or
  non-symlink `~/bin` is never replaced. After a successful fetch, a
  non-fast-forward update also remains fatal instead of hiding local divergence.

Nixbot now defers its controller-then-registries control-plane unit to the
latest position allowed by the dependency graph unless
`NIXBOT_CONTROL_PLANE_FIRST=1` or `--control-plane-first` is explicit. `pvl-x2`
is the CI controller, builder, transfer broker, Nix cache owner, and parent of
the lab controllers. The resulting default deploy waves are:

1. `pvl-a1` and `pvl-l5`.
2. `pvl-x2` alone.
3. `pvl-vlab` and `pvl-vlab-1`.
4. `pvl-vk` and `pvl-vk-1`.

This lets independent consumers finish copying from the old, known-working cache
before its owner activates, while preserving parent-before-child ordering for
the guests routed through `pvl-x2`. The explicit CI-first mechanism remains
available for exceptional runs.

The repair is validated by the full packaged Nixbot helper suite, focused Pvl
wave assertions, a complete `pvl-vk-1` system build, and ShellCheck of the
generated dotfiles script. It has not been deployed.

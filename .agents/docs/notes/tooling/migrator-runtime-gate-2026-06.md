# Migrator Runtime Gate 2026-06

`services.migration-manager` is the runtime-owned migration drain for
repo-managed host services.

The old x-level drain switch was generation-owned: agents had to patch host
modules and run a full deploy to stop services and suppress cold-start. The new
model keeps the drain under a dedicated module and package:

- `services.migration-manager.enable = true` installs `migratorctl` and the
  host-local runtime helpers.
- `services.migration-manager.state = "runtime" | "on" | "off"` declares gate
  ownership. `runtime` is the default and leaves the transient live gate
  untouched during switch. `on` forces the host drained declaratively. `off`
  forces the host resumed declaratively.
- `services.migration-manager.gatePath` is the read-only Nix-owned gate marker
  path.
- `services.migration-manager.managedUnits` is the service-owned registration
  API for system services and dispatcher units that participate in the drain.
- `migratorctl on|off|apply|status` changes the live gate dynamically through
  the transient gate marker and `migrator-apply.service`.

The runtime gate file is fixed by read-only Nix config at `/run/migrator/gate`.
This is the only runtime state the migrator owns, and it is intentionally
transient.

For declarative boot defaults, `services.migration-manager.state = "on"` or
`"off"` is also reflected in tmpfiles rules. A drained generation creates the
marker before normal `multi-user.target` services are started; a forced-resumed
generation removes a stale marker before those services start. In the default
`"runtime"` state, tmpfiles and `migrator-sync.service` leave the marker
untouched so `migratorctl on|off` remains live across switch within the current
boot. Reboot clears runtime state unless the declared generation sets
`state = "on"`. `migrator-sync` still runs before gated system-level units and
queues `migrator-apply.service` with systemd `--no-block` so gated units are
never started from inside the unit they are ordered after.

When the gate file is present:

- package-backed system services generated through
  `lib/flake/service-module.nix` register under
  `services.migration-manager.managedUnits.system`, then the migrator module
  orders them after `migrator-sync.service`, blocks startup through
  `ConditionPathExists=!<gate>`, and includes them in the generated manifest;
- `systemd-user-manager` still owns user-service stop/start, but its reconciler
  reads the gate dynamically and treats all managed user units as
  `autoStart =
  false` and `state = "stopped"` while drained; it also avoids
  starting its ready target while the gate is on, so managed user units do not
  cold-start;
- podman-compose stays agnostic because its workloads are started and stopped
  through the user-manager control plane;
- host-managed Cloudflare tunnel units stay declared, but they are blocked at
  startup through the same service-owned registry and included in the migrator
  manifest.

`migrator-apply.service` uses the generated manifest exported through
`MIGRATOR_MANIFEST` to:

1. stop migrator-managed system units when the gate is on;
2. start those system units when the gate is off;
3. trigger all managed systemd-user dispatchers so user units reconcile against
   the live gate state.

The manifest booleans are real opt-outs, so helper jq filters must distinguish
missing keys from explicit `false` values. Do not write `.stopOnDrain // true`
or `.startOnResume // true`; in jq, `//` also defaults `false`. Use `has("...")`
around the key-specific default instead.

`migrator-apply.service` is intentionally a non-persistent oneshot, and
`migratorctl` restarts it for each local or remote gate change. Managed
systemd-user dispatcher units are persistent oneshots, so the helper restarts
them when applying the gate to force a fresh reconciliation pass.

`data-migrator` now uses `migratorctl remote on|off --host <nixbot-host>` for
source drain/resume instead of creating temporary worktrees that patch host
modules. Target bootstrap still uses a temporary drained generation. Target
resume deploys the normal generation, then turns the runtime gate off with
`migratorctl`, leaving the normal `"runtime"` ownership mode with an absent gate
file and no persistent migrator state. The temporary bootstrap override is
service-owned: `data-migrator` rewrites
`lib/services/migrator/bootstrap-hosts.nix` inside the temporary worktree, not
`hosts/default.nix`.

Remote gate changes require the remote host to already expose
`/run/current-system/sw/bin/migratorctl`. The target bootstrap deploy provides
that for the target host; source drain hosts must be pre-deployed with migrator
support or intentionally handled out of band.

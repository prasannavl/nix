# Migration Manager Runtime Gate 2026-06

`services.migration-manager` is the runtime-owned migration drain for
repo-managed host services.

The old x-level drain switch was generation-owned: agents had to patch host
modules and run a full deploy to stop services and suppress cold-start. The new
model keeps the drain under a dedicated module and package:

- `services.migration-manager.enable = true` installs `migration-manager` and
  the host-local runtime helpers.
- The package lives at `pkgs/tool/migration-manager` and is exported as
  `pkgs.migration-manager`.
- `services.migration-manager.state = "runtime" | "on" | "off"` declares gate
  ownership. `runtime` is the default and leaves the transient live gate
  untouched during switch. `on` forces the host drained declaratively. `off`
  forces the host resumed declaratively.
- `services.migration-manager.gatePath` is the read-only Nix-owned gate marker
  path.
- `services.migration-manager.managedUnits` is the service-owned registration
  API for system services plus native `systemd.user` services and targets that
  participate in the drain.
- `migration-manager on|off|apply|status` changes the live gate dynamically
  through the transient gate marker and `migration-manager-apply.service`.

The runtime gate file is fixed by read-only Nix config at
`/run/migration-manager/gate`. This is the only runtime state migration-manager
owns, and it is intentionally transient.

For declarative boot defaults, `services.migration-manager.state = "on"` or
`"off"` is also reflected in tmpfiles rules. A drained generation creates the
marker before normal `multi-user.target` services are started; a forced-resumed
generation removes a stale marker before those services start. In the default
`"runtime"` state, tmpfiles and `migration-manager-sync.service` leave the
marker untouched so `migration-manager on|off` remains live across switch within
the current boot. Reboot clears runtime state unless the declared generation
sets `state = "on"`. `migration-manager-sync.service` still runs before gated
system-level units, but runtime mode does not queue
`migration-manager-apply.service`: a normal switch must not create a second
full-user convergence owner after NixOS has already reconciled the native unit
graph. Declarative `on` or `off` generations queue apply with systemd
`--no-block`, and explicit `migration-manager on|off|apply` commands restart the
apply unit directly.

When the gate file is present:

- package-backed system services generated through
  `lib/flake/service-module.nix` register under
  `services.migration-manager.managedUnits.system`, then the migration-manager
  module orders them after `migration-manager-sync.service`, blocks startup
  through `ConditionPathExists=!<gate>`, and includes them in the generated
  manifest;
- native `systemd.user` services registered under
  `services.migration-manager.managedUnits.users.<user>.services` are stopped
  explicitly and blocked from cold-starting with `ConditionPathExists=!<gate>`;
- native `systemd.user` targets registered under
  `services.migration-manager.managedUnits.users.<user>.targets`, such as
  `<user>-managed.target`, are stopped or started according to their
  registration and blocked from cold-starting with
  `ConditionPathExists=!<gate>`;
- podman-compose keeps `<user>-managed.target` as the only aggregate stop/start
  owner for auto-start graphs. It also registers each auto-start main,
  reconcile, verify, and ready node with `gateStart = true`,
  `stopOnDrain = false`, and `startOnResume = false`, so direct NixOS
  changed-unit starts cannot bypass the runtime gate or create duplicate
  migration-manager orchestration. The shared mutating runtime preflight uses
  the same gate-only registration and remains a hard requirement of main
  execution. Stage and image-pull units stay available as non-live preparation
  while drained;
- host-managed Cloudflare tunnel units stay declared, but they are blocked at
  startup through the same service-owned registry and included in the
  migration-manager manifest.

`migration-manager-apply.service` uses the generated manifest exported through
`MIGRATION_MANAGER_MANIFEST` to:

1. stop migration-manager-managed system units when the gate is on;
2. stop registered native user targets and services when the gate is on;
3. start migration-manager-managed system units when the gate is off;
4. start registered native user services and targets when the gate is off.

The manifest booleans are real opt-outs, so helper jq filters must distinguish
missing keys from explicit `false` values. Do not write `.stopOnDrain // true`
or `.startOnResume // true`; in jq, `//` also defaults `false`. Use `has("...")`
around the key-specific default instead.

`migration-manager-apply.service` is intentionally a non-persistent oneshot, and
`migration-manager` restarts it for each local or remote gate change. It talks
directly to each registered user manager with `systemctl --user`; there is no
dispatcher hop in the native model.

Deploy `cjIpsc` confirmed why runtime sync must not auto-apply. A prior runtime
apply was still resuming the complete managed target while the normal NixOS user
switch started the changed native units, producing a duplicate full-stack start
wave. The runtime sync unit now preserves gate state and ordering only; apply is
reserved for an actual gate-state owner change.

`data-migrator` now uses `migration-manager remote on|off --host <nixbot-host>`
for source drain/resume instead of creating temporary worktrees that patch host
modules. Target bootstrap still uses a temporary drained generation. Target
resume deploys the normal generation, then turns the runtime gate off with
`migration-manager`, leaving the normal `"runtime"` ownership mode with an
absent gate file and no persistent migration-manager state. The temporary
bootstrap override is service-owned: `data-migrator` rewrites
`lib/services/migration-manager/bootstrap-hosts.nix` inside the temporary
worktree, not `hosts/default.nix`.

Remote gate changes require the remote host to already expose
`/run/current-system/sw/bin/migration-manager`. The target bootstrap deploy
provides that for the target host; source drain hosts must be pre-deployed with
migration-manager support or intentionally handled out of band.

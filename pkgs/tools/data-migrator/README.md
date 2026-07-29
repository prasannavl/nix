# data-migrator

`data-migrator` copies declared host state paths. In full migrations it can
first deploy the target host into a declarative drained generation, then use
runtime `migration-manager` drain/resume calls around the final cutover copy.

Incus project move with automatic path selection:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --source-project old-project \
  --target-project new-project
```

The instance name defaults to the profile name. If the source and target are on
the same Incus remote and the root disk is on the same btrfs storage pool, the
tool uses an Incus-native snapshot/refresh copy. Otherwise it falls back to the
declared file paths, choosing `rsync` when available and `tar` streaming when it
is not.

Warm seed only:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --target-host new-host \
  --warm
```

Full drain/copy/resume flow:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --source-host old-host \
  --source-drain-host old-host \
  --target-host new-host
```

That full flow does two distinct control actions:

1. a one-time drained bootstrap deploy for the target host, so the new
   generation, secrets, users, and runtime directories exist before the seed
   copy, and
2. runtime `migration-manager` gate toggles for the target and source hosts
   during the final sync window.

When the target resumes, `data-migrator` deploys the normal target generation
again, then flips the runtime gate off. That returns the host to the default
runtime-owned mode with no drain marker and no persistent migration-manager
state.

Remote gate toggles require the remote host to already run a generation that
contains `services.migration-manager` and
`/run/current-system/sw/bin/migration-manager`. The target bootstrap deploy
establishes that for the target. Source drain hosts should be pre-deployed with
migration-manager support, or already drained when using `--skip-deploy`.

`services.migration-manager.state` is tri-state. The normal default is
`"runtime"`, which keeps `migration-manager on|off` state live across switch
within the current boot. The target bootstrap deploy temporarily forces `"on"`
in its private worktree; target resume deploys the normal generation and runs
`migration-manager off` so the host returns to runtime-owned gate control.

Local staging copy:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --source-host old-host \
  --target-dir /srv/migration/app \
  --warm
```

Concrete host profiles are repository policy rather than shared tool behavior.
Use a checked-in profile name when the owning repository provides one, or put a
migration plan in an explicit YAML file and pass it with `--config`.
`--source-host` is optional when the plan declares `source_host`; the command
line value wins when both are set. `target_path_base` is the destination root
used to map each copied source path onto the target and is required unless
`--target-base` is passed.

```yaml
source_host: old-host
source_paths:
  - /var/lib/app/postgres
  - /var/lib/app/uploads
  - "!./compose/"
  - "!/var/lib/app/uploads/cache/"
target_path_base: /var/lib/app
```

Plain `source_paths` entries are copied. Entries beginning with `!` are exclude
patterns; quote them because YAML treats an unquoted `!` as a tag marker.
Exclude patterns must either be full absolute paths, or relative patterns
starting with `./`. `!./tmp/` applies inside every copied path, while
`!/var/lib/app/uploads/cache/` applies only when copying `/var/lib/app/uploads`.

The Nix package accepts a repository-provided `migrationProfiles` attribute set,
serializes it into YAML files in the store, and sets `DATA_MIGRATOR_CONFIG_DIR`
for the Python tool. Its default is empty. Concrete inventory remains owned by
the repository that declares and injects it.

Source-side reads default to running remote rsync through Nix:
`sudo -n nix shell nixpkgs#rsync -c rsync`. This keeps migrations working from
minimal NixOS hosts that have Nix but do not already have `rsync` in
`environment.systemPackages`. Override it with `--source-rsync-path` when
migrating from a non-NixOS host or from a host with a different rsync location.

The default remote copy mode is `pull`: the target host runs `rsync` and pulls
from the source host. Use `--copy-mode push` if the source host should run
`rsync` and push to the target.

Every copy mode runs `rsync` with aggregate progress enabled and unbuffered
output, so long-running seed and final copies stream progress while they run.
When `--transport auto` cannot use `rsync`, the tar fallback replaces the
destination path contents before extracting so final copies do not leave stale
files behind.

When the source host is reachable only through a bastion, pass an rsync remote
shell:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --target-dir ./tmp/data/ \
  --skip-deploy \
  --rsync-ssh 'ssh -J bastion -o HostKeyAlias=old-host'
```

## Incus project migration

Incus mode is enabled by `--target-project`, `--source-project`, or
`--source-instance` / `--incus-instance`. The minimal generic form for a
controller whose default Incus project is already correct is:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --incus-controller-host parent-host \
  --source-instance old-instance \
  --target-instance new-instance
```

For explicit cross-project moves, pass the project names:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --source-project old-project \
  --target-project new-project
```

The migration plan can supply host data paths, the default `source_host`, and
Incus settings under `incus`:

```yaml
incus:
  controller_host: parent-host
  instance: old-instance
  source_project: old-project
  target_project: new-project
  remote: local
```

When `controller_host` or `--incus-controller-host` is set, all Incus client
operations run over SSH on that host. This is useful for delegated controllers
where the Incus remotes, client certificates, and project access are already
configured. `remote: local` then means the controller's local/default Incus
client context, not the operator laptop. When project flags are omitted, the
controller's default Incus project is used; `--target-project` is added to
`incus copy` only for cross-project moves.

When the target instance already exists, native Incus refreshes are guarded. The
`data-migrator` stamps targets it creates or refreshes with
`user.data-migrator.*` source markers. A later refresh is allowed only when
those markers match the requested source. Use `--force-refresh-existing` to
refresh an existing target without a matching marker.

The fast path is selected only when the source and target Incus remote are the
same and the target storage pool is the same btrfs pool as the source root disk.
The flow is:

1. create a temporary source snapshot while the source is still live,
2. copy or refresh the target instance with `incus copy`,
3. for full migrations, deploy the target host into a drained generation unless
   `--skip-deploy` is set,
4. for full migrations, drain source writers with `migration-manager on` unless
   `--skip-deploy` is set,
5. stop the source instance and stop the current target instance,
6. create the final source snapshot and run a final `incus copy --refresh`,
7. start the target instance when the source or target had been running before
   the final refresh, unless `--no-start-target --no-resume-target` is set,
8. remove the temporary migration snapshots.

The first copy is allowed to be inconsistent by default because it is only the
warm seed. The final copy runs after the source instance is stopped, so the
target is the authoritative crash-consistent state; with nixbot drains enabled,
service state is app-consistent before that stop.

If the btrfs fast path is not available, file-copy fallback uses the same
bootstrap/seed/final/drain ordering as the existing data migration flow. It
requires `--target-host` or `--target-dir` because there must be a destination
filesystem to receive the declared profile paths.

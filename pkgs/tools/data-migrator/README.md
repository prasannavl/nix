# data-migrator

`data-migrator` copies declared host state paths and can move Incus containers
with native `incus copy` refreshes when the source and target are compatible.

The checked-in package is generic. It intentionally does not include host
migration profiles, host names, secret paths, or automatic nixbot drain/resume
patching. Put concrete plans in an explicit YAML file and pass it with
`--config`.

Warm seed only:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --source-host old-host \
  --target-host new-host \
  --warm
```

Final file copy:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --source-host old-host \
  --target-host new-host
```

The file-copy plan declares paths and optional excludes:

```yaml
source_paths:
  - /var/lib/app/postgres
  - /var/lib/app/uploads
  - "!./tmp/"
  - "!/var/lib/app/uploads/cache/"
target_path_base: /var/lib/app
```

Plain `source_paths` entries are copied. Entries beginning with `!` are exclude
patterns; quote them because YAML treats an unquoted `!` as a tag marker.
Exclude patterns must either be full absolute paths, or relative patterns
starting with `./`. `!./tmp/` applies inside every copied path, while
`!/var/lib/app/uploads/cache/` applies only when copying `/var/lib/app/uploads`.

Source-side reads default to running remote rsync through Nix:
`sudo -n nix shell nixpkgs#rsync -c rsync`. This keeps migrations working from
minimal NixOS hosts that have Nix but do not already have `rsync` in
`environment.systemPackages`. Override it with `--source-rsync-path` when
migrating from a non-NixOS host or from a host with a different rsync location.

The default remote copy mode is `pull`: the target host runs `rsync` and pulls
from the source host. Use `--copy-mode push` if the source host should run
`rsync` and push to the target. Every rsync copy uses aggregate progress and
unbuffered output. When `--transport auto` cannot use `rsync`, the tar fallback
replaces the destination path contents before extracting so final copies do not
leave stale files behind.

When the source host is reachable only through a bastion, pass an rsync remote
shell:

```bash
data-migrator --profile app \
  --config ./tmp/app-migration.yaml \
  --target-dir ./tmp/data/ \
  --rsync-ssh 'ssh -J bastion -o HostKeyAlias=old-host'
```

## Incus Moves

Incus mode is enabled by `--target-project`, `--source-project`, or
`--source-instance` / `--incus-instance`.

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

Incus settings can also be declared in YAML:

```yaml
incus:
  controller_host: parent-host
  instance: old-instance
  source_project: old-project
  target_project: new-project
  remote: local
```

When `controller_host` or `--incus-controller-host` is set, all Incus client
operations run over SSH on that host. `remote: local` then means the
controller's local/default Incus client context, not the operator laptop. When
project flags are omitted, the controller's default Incus project is used;
`--target-project` is added to `incus copy` only for cross-project moves.

When the target instance already exists, native Incus refreshes are guarded. The
migrator stamps targets it creates or refreshes with `user.data-migrator.*`
source markers. A later refresh is allowed only when those markers match the
requested source. Use `--force-refresh-existing` to refresh an existing target
without a matching marker.

The fast path is selected only when the source and target Incus remote are the
same and the target storage pool is the same btrfs pool as the source root disk.
The flow is:

1. create a temporary source snapshot while the source is still live,
2. copy or refresh the target instance with `incus copy`,
3. stop the source instance,
4. stop an existing target instance if needed,
5. create the final source snapshot and run a final `incus copy --refresh`,
6. start the target instance when the source or previous target was running,
7. remove the temporary migration snapshots.

The first copy is allowed to be inconsistent by default because it is only the
warm seed. The final copy runs after the source instance is stopped, so the
target is the authoritative crash-consistent state.

If the btrfs fast path is not available, file-copy fallback uses the same
seed/final ordering as the file migrator. It requires `--target-host` or
`--target-dir` because there must be a destination filesystem to receive the
declared profile paths.

For repo-managed Incus LXCs, drain source writers through
`services.incusMachines.<project>.instances.<name>.drain = true` before the
final migration when app-consistent state is required. The data migrator does
not patch or deploy that policy automatically.

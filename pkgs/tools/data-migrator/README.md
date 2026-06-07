# data-migrator

`data-migrator` copies declared host state paths. In full migrations it can
first deploy the target host into a declarative drained generation, then use
runtime `migratorctl` drain/resume calls around the final cutover copy.

Incus project move with automatic path selection:

```bash
data-migrator --profile abird-corp \
  --source-project abird \
  --target-project abird-stage
```

The Abird profiles include `incus.controller_host = "abird-nest"`, so Incus
operations run through the delegated controller by default. The instance name
defaults to the profile name. If the source and target are on the same Incus
remote and the root disk is on the same btrfs storage pool, the tool uses an
Incus-native snapshot/refresh copy. Otherwise it falls back to the declared file
paths, choosing `rsync` when available and `tar` streaming when it is not.

Warm seed only:

```bash
data-migrator --profile abird-corp \
  --target-host abird-corp \
  --warm
```

Full drain/copy/resume flow:

```bash
data-migrator --profile abird-corp \
  --source-host old-abird-corp \
  --source-drain-host old-abird-corp \
  --target-host abird-corp
```

That full flow does two distinct control actions:

1. a one-time drained bootstrap deploy for the target host, so the new
   generation, secrets, users, and runtime directories exist before the seed
   copy, and
2. runtime `migratorctl` gate toggles for the target and source hosts during the
   final sync window.

When the target resumes, `data-migrator` deploys the normal target generation
again, then flips the runtime gate off. That returns the host to the default
runtime-owned mode with no drain marker and no persistent migrator state.

Remote gate toggles require the remote host to already run a generation that
contains `services.migrator` and `/run/current-system/sw/bin/migratorctl`. The
target bootstrap deploy establishes that for the target. Source drain hosts
should be pre-deployed with migrator support, or already drained when using
`--skip-deploy`.

`services.migrator.state` is tri-state. The normal default is `"runtime"`, which
keeps `migratorctl on|off` state live across switch within the current boot. The
target bootstrap deploy temporarily forces `"on"` in its private worktree;
target resume deploys the normal generation and runs `migratorctl off` so the
host returns to runtime-owned gate control.

Local staging copy:

```bash
data-migrator --profile abird-corp \
  --source-host old-abird-corp \
  --target-dir /srv/migration/abird-corp \
  --warm
```

Host plans are defined in `pkgs/tools/data-migrator/profiles.nix`.
`--source-host` is optional when the plan declares `source_host`; the command
line value wins when both are set. `target_path_base` is the destination root
used to map each copied source path onto the target.

```yaml
source_host: 10.10.30.60
source_paths:
  - /var/lib/abird/open-webui
  - "!./compose/"
  - "!/var/lib/abird/open-webui/cache/"
target_path_base: /var/lib/abird
```

Plain `source_paths` entries are copied. Entries beginning with `!` are exclude
patterns; quote them because YAML treats an unquoted `!` as a tag marker.
Exclude patterns must either be full absolute paths, or relative patterns
starting with `./`. `!./tmp/` applies inside every copied path, while
`!/var/lib/abird/open-webui/cache/` applies only when copying
`/var/lib/abird/open-webui`.

The Nix package serializes `profiles.nix` into YAML files in the store and sets
`DATA_MIGRATOR_CONFIG_DIR` for the Python tool. `--config` can still point at an
explicit YAML file for ad hoc runs.

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
data-migrator --profile abird-data \
  --target-dir ./tmp/data/ \
  --skip-deploy \
  --rsync-ssh 'ssh -J gap3-gondor -o HostKeyAlias=abird-data'
```

## Incus project migration

Incus mode is enabled by `--target-project`, `--source-project`, or
`--source-instance` / `--incus-instance`. The minimal generic form for a
controller whose default Incus project is already correct is:

```bash
data-migrator --profile HOST \
  --incus-controller-host abird-nest \
  --source-instance old-instance \
  --target-instance new-instance
```

For Abird, the controller-only profile already knows that controller:

```bash
data-migrator --profile abird-nest \
  --source-instance abird-corp \
  --target-instance abird-corp-2
```

For explicit cross-project moves, pass the project names:

```bash
data-migrator --profile HOST \
  --source-project old-project \
  --target-project new-project
```

The profile still supplies repo-specific host data paths and the default
`source_host`. The checked-in Abird profiles also supply the controller host;
the Incus settings can be declared in YAML under `incus`:

```yaml
incus:
  controller_host: abird-nest
  instance: abird-corp
  source_project: abird
  target_project: abird-stage
  remote: local
```

When `controller_host` or `--incus-controller-host` is set, all Incus client
operations run over SSH on that host. This is useful for delegated controllers
such as `abird-nest`, where the Incus remotes, client certificates, and project
access are already configured on the controller. `remote: local` then means the
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
3. for full migrations, deploy the target host into a drained generation unless
   `--skip-deploy` is set,
4. for full migrations, drain source writers with `migratorctl on` unless
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
bootstrap/seed/final/drain ordering as the existing data migrator. It requires
`--target-host` or `--target-dir` because there must be a destination filesystem
to receive the declared profile paths.

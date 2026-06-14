# podman-compose: per-entry ownership + mode for staged dirs/files (2026-04)

## Summary

`services.podman-compose.<stack>.instances.<name>` staged directory and file
entries now declare ownership and mode alongside their content. The helper
applies them after staging, every `start`/`reload`/`image-pull`, so permissions
never drift back to the stack-user default.

Affected options:

- `dirs.<dst>` — submodule: `mode` (default 0750) / `user` / `group` / `scope` /
  `once`. Use this for directory bind mounts and restrictive parent directories.
- `files.<dst>` — submodule: `text` / `source` / `mode` (default `"none"`) /
  `user` / `group` / `scope`. Bare string and path shorthands still coerce to
  `{ text = <str>; }` or `{ source = <path>; }` with defaults. `mode =
  "none"`
  preserves the copied source mode.
- `fileSecrets.<name>` — submodule: `file` / `mode` (default 0400) / `user` /
  `group` / `scope`. Bare string coerces to `{ file = <str>; }`.

`envSecrets.<composeService>` is now intentionally a plain attrs-of-strings
mapping from environment variable name to host secret path. Ownership settings
no longer apply to env-secret files.

`scope` defaults to `"host"`. Setting `scope = "container"` makes the helper run
`chmod` and `chown` via `podman unshare`, which applies mode and numeric uid/gid
inside the rootless user namespace (container 1000 ↔ host `SUB + 999`, where
`SUB` is the first column of the stack user's entry in `/etc/subuid`). A
module-level assertion rejects non-numeric `user`/`group` when owner fields are
set with `scope = "container"` because the userns has no name resolution.

## Why

Before this change, everything staged by the helper ended up owned by the stack
user (e.g. host uid 2000 → container root). Image-built services that ran as a
non-root uid inside the container (PostgreSQL uid 1000, NATS, etc.) could only
read those files via the directory's "other" permission bit, which forced either
overly permissive dir modes or bespoke `preStart` `podman unshare chown` dances
tied to each service.

Giving each file entry an explicit in-container owner removes the workarounds,
re-applies every start, and keeps ownership aligned with the container process
identity that actually reads the file.

Directory entries need one extra step: a container-scoped directory is not
normally writable by the host stack user after finalization. The helper
therefore prepares managed `dirs` back to stack-user-writable ownership before
staging or cleanup, and finalizes them to the declared mode/owner after file
staging.

Ownerless dirs can also be create-only via `once = true`: the helper creates and
initializes the directory when missing, but leaves existing persistent state
untouched. The compatibility default is create-only for ownerless dirs without
staged children, and managed for explicit owners or staged-file parents.

## Consumer change

`hosts/gap3-rivendell/services/postgres.nix`:

- `fileSecrets` now owns the TLS material (`ca.crt`, `server.crt`, `server.key`)
  with `scope = "container"`, `user = 1000`, `group = 1000`, and appropriate
  modes (0600 for the key).
- `dirs."conf.d"` owns the directory bind mount with the same container-scoped
  owner and mode 0750, so PostgreSQL no longer depends on the world-execute bit
  to traverse `/etc/postgresql/conf.d`.
- `files."conf.d/*"`, `files."pg_hba.conf"`, and `files."initdb/*"` carry the
  same container-scoped ownership, letting the helper chown them after copy.
- `pg_hba.conf` is mounted outside `conf.d`; the existing
  `include_dir = '/etc/postgresql/conf.d'` parses only server config fragments,
  while `hba_file` points directly at `/etc/postgresql/pg_hba.conf`.
- The `preStart` hook now only handles the external PostgreSQL data directory
  (`/var/lib/gap3/postgres`), which sits outside the compose working dir.

## Metadata shape

Helper metadata (JSON) gained `stagedDirs`, and `stagedFiles` now includes both
normal staged files and file secrets. File entries carry `dstDirMode` alongside
`mode`, `user`, `group`, and `scope`, so the helper can stage all copied files
through one loop. `stagedDirs` carry the same ownership fields plus the resolved
`once` behavior; env-secret files keep the helper's fixed default mode behavior.
The bash helper's `apply_perms` applies file permissions on the temp path before
rename, and managed directory permissions are finalized after all files are
staged.

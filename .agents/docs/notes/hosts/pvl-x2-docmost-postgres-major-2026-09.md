# PVL-X2 Docmost PostgreSQL Major Boundary (2026-09)

## Incident

The 2026-09-14 fleet deploy activated successfully but failed the `pvl-x2`
health check because `pvl-docmost.service` and its ready target were inactive.
The retained deploy diagnostics and live user journal showed that activation
drained the previously healthy Docmost project, then its PostgreSQL container
exited during recreation.

The image refresh in `aa76a559` changed Docmost from `postgres:16-alpine` to
`postgres:18-alpine`. The persisted `db-data/PG_VERSION` remained `16`, and the
PostgreSQL 18 image rejected the old cluster and `/var/lib/postgresql/data`
mount. The compose helper then removed only the failed attempt's containers,
pod, network, and anonymous volume; the bind-mounted database remained intact.

## Decision

- Restore Docmost to `postgres:16-alpine`; do not attempt an implicit database
  migration during service activation.
- Treat the official PostgreSQL image's declared major as a release track in
  `podman-image-updater.py`. Automated refreshes may stay on that track but must
  not select a different PostgreSQL major.
- A future PostgreSQL major upgrade is an explicit operator migration. It must
  include a backup, a tested `pg_upgrade` or dump/restore procedure, the
  PostgreSQL 18 mount-layout change, and separately authorized live execution.

## Recovery and validation

The updater regression suite, real image report, repository lint, evaluated
Docmost source, and non-activating `pvl-x2` closure build passed. The image
report now classifies `postgres:16-alpine` as current within its selected major
track.

Nixbot's plain `--dirty` mode allowed the dirty repository but isolated the
committed tree, so it reused the old plan and skipped activation. The explicit
`--dirty-staged` overlay planned and deployed the repaired closure. Nixbot's
post-deploy health check passed, and independent live checks confirmed:

- `pvl-docmost.service` and `pvl-docmost-ready.target` are active with
  successful results.
- The Docmost, PostgreSQL 16, and Redis containers are running.
- The retained cluster still reports `PG_VERSION=16`, and PostgreSQL accepts
  connections.
- The local Docmost origin returns HTTP 200, and the user manager has no failed
  units.

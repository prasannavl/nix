# pgadmin4 `pg_attver` Backport

## Scope

Why `lib/overlays/pgadmin4/` patches nixpkgs' `pgadmin4` 9.14, and when the
override can be deleted.

## Failure

- PostgreSQL minors 17.12/18.7 started storing an internal `pg_attver=<n>` entry
  in `pg_attribute.attoptions` for every attribute. `pg_`-prefixed options
  cannot be set through DDL.
- pgadmin 9.14 read `attoptions` verbatim, so reverse-engineered SQL gained
  `ALTER ... SET (pg_attver=...)` and `regression/re_sql` failed
  (`ReverseEngineeredSQLTestCases`), failing the whole `pgadmin4` build — seen
  as a `pvl-a1` fleet build failure after ~42 min on the 2026-11-24 nixpkgs bump
  (postgresql 17.11 → 17.12).

## Fix

- `ignore-internal-column-options.patch` backports upstream PR
  pgadmin-org/pgadmin4#10780 (commit 88c3ac2) onto REL-9_14: every template that
  selects column `attoptions` filters `pg_`-prefixed entries with
  `NULLIF(ARRAY(SELECT o FROM unnest(attoptions) AS o WHERE left(o, 3) <> 'pg_'), '{}')`.
- REL-9_14 needs the filter in six files (upstream's patch covers four): the
  versioned variants
  `tables/columns/sql/{default,12_plus,14_plus}/properties.sql` and
  `foreign_tables/.../sql/{default,12_plus}/get_columns.sql`. 9.14 does not
  select `attoptions` for index columns, so upstream's `column_details.sql` hunk
  is not backported.
- Keep `doCheck` enabled; the point is to keep the suite meaningful instead of
  skipping it.
- Placement: the unit is an overlay (it overrides a nixpkgs package, so it
  cannot be a manifest-registered `pkgs/ext/` package), and it is multi-file, so
  it is `lib/overlays/pgadmin4/default.nix` plus its patch — one namespace, one
  directory, matching the "never keep both `foo.nix` and `foo/`" rule.

## Verification

- `nix build` of `pvl-a1`'s `pgadmin4-desktopmode`: browser suite 1292 passed /
  0 failed, resql suite 1 passed / 0 failed (unpatched: resql failed).

## Removal

- Drop `lib/overlays/pgadmin4/` and the `(import ./pgadmin4)` entry once the
  packaged pgadmin contains PR 10780; nixpkgs master carries the same backport
  for 9.19.

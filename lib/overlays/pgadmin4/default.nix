_final: prev: {
  # PostgreSQL 17.12/18.7 keep an internal pg_attver column option in
  # pg_attribute.attoptions; pgadmin 9.14 renders it as
  # "ALTER ... SET (pg_attver=...)" and its resql tests fail. Backport of
  # https://github.com/pgadmin-org/pgadmin4/pull/10780 until 9.15+ is packaged.
  pgadmin4 = prev.pgadmin4.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./ignore-internal-column-options.patch];
  });
}

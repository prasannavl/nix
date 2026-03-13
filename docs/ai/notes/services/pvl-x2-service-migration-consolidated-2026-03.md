# pvl-x2 Service Migration Consolidated Notes (2026-03)

## Scope

Canonical summary of the March 2026 `pvl-x2` service migration into repo-managed
Podman compose stacks, including initial service adoption and the secret-layout
cleanup that followed.

## Host adoption

- `hosts/pvl-x2/services.nix` is the repo-managed home for the `pvl` user-run
  compose stacks.
- Early migration moved `beszel`, `dockge`, `docmost`, and `immich` into
  `services.podmanCompose`.
- Compose trees live under `hosts/pvl-x2/compose/` and materialize into managed
  runtime directories.

## Secret migration outcome

- Active plaintext service secrets moved to encrypted repo-managed files under
  `data/secrets/services/<service>/`.
- Encrypted payloads use the `.key.age` suffix so they align with
  `scripts/age-secrets.sh` expectations.
- `scripts/age-secrets.sh` now covers all managed entries from
  `data/secrets/default.nix`, including `data/secrets/services/**/*.key.age`.

## Active migrated secrets

- `beszel`: `KEY`, `TOKEN`
- `docmost`: `APP_SECRET`, `DATABASE_URL`, `POSTGRES_PASSWORD`
- `immich`: `DB_PASSWORD` / `POSTGRES_PASSWORD`
- `shadowsocks`: `PASSWORD`
- `zulip` remained inactive and still needs the same treatment before
  re-enablement.

## Practical interpretation

- `pvl-x2` services are now repo-managed under the shared Podman compose model.
- Service secrets are encrypted, included in the default `age-secrets.sh` scope,
  and named consistently with the rest of `data/secrets`.

## Superseded notes

- `docs/ai/notes/age-secrets-default-scope-2026-03-09.md`
- `docs/ai/notes/pvl-x2-beszel-podman-compose.md`
- `docs/ai/notes/pvl-x2-service-secret-key-suffix-2026-03-09.md`

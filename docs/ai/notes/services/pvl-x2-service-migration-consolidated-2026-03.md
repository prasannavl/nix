# pvl-x2 Service Migration Consolidated Notes (2026-03)

## Scope

Canonical summary of the March 2026 `pvl-x2` service migration into repo-managed
Podman compose stacks, including initial service adoption and the secret-layout
cleanup that followed.

## Host adoption

- `hosts/pvl-x2/services.nix` became the repo-managed home for the `pvl`
  user-run compose stacks.
- The early migration brought `beszel`, `dockge`, `docmost`, and `immich` into
  `services.podmanCompose`.
- Compose trees live under `hosts/pvl-x2/compose/` and materialize into managed
  stack directories at runtime.
- Firewall alignment was updated for the adopted services, including Beszel on
  `8090` and Dockge on `5001`.

## Secret migration outcome

- Active plaintext service secrets were moved to encrypted repo-managed files
  under `data/secrets/services/<service>/`.
- Encrypted payloads now use the `.key.age` suffix so they match the plaintext
  naming convention expected by `scripts/age-secrets.sh`.
- `scripts/age-secrets.sh` default scope now includes all managed entries from
  `data/secrets/default.nix`, including `data/secrets/services/**/*.key.age`.
- `hosts/pvl-x2/services.nix` and `data/secrets/default.nix` were updated to
  match the renamed service-secret paths.

## Active migrated secrets

- `beszel`: `KEY`, `TOKEN`
- `docmost`: `APP_SECRET`, `DATABASE_URL`, `POSTGRES_PASSWORD`
- `immich`: `DB_PASSWORD` / `POSTGRES_PASSWORD`
- `shadowsocks`: `PASSWORD`
- `zulip` remained inactive and still needs the same treatment before
  re-enablement.

## Practical interpretation

- `pvl-x2` service definitions are now repo-managed and compatible with the
  consolidated Podman compose platform model.
- Service secrets are encrypted, default-managed by `age-secrets.sh`, and named
  consistently with the rest of `data/secrets`.

## Superseded notes

- `docs/ai/notes/age-secrets-default-scope-2026-03-09.md`
- `docs/ai/notes/pvl-x2-beszel-podman-compose.md`
- `docs/ai/notes/pvl-x2-service-secret-key-suffix-2026-03-09.md`

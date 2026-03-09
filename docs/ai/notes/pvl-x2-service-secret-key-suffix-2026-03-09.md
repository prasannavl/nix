# `pvl-x2` Service Secret `.key.age` Suffix Alignment (2026-03-09)

## Context

- Repo-managed encrypted service secrets for `pvl-x2` live under
  `data/secrets/services/<service>/*.age`.
- `scripts/age-secrets.sh` and related workflows assume the encrypted form of a
  managed secret is `<plaintext>.age`, where the plaintext file is expected to
  carry the `.key` suffix.

## Decision

- Rename the encrypted service secret payloads under
  `data/secrets/services/` from `*.age` to `*.key.age`.
- Update the `hosts/pvl-x2/services.nix` secret loader to resolve
  `${resolvedFileName}.key.age`.
- Update `data/secrets/default.nix` recipient-map entries to the renamed files.

## Renamed files

- `data/secrets/services/beszel/key.key.age`
- `data/secrets/services/beszel/token.key.age`
- `data/secrets/services/docmost/app-secret.key.age`
- `data/secrets/services/docmost/database-url.key.age`
- `data/secrets/services/docmost/postgres-password.key.age`
- `data/secrets/services/immich/db-password.key.age`
- `data/secrets/services/shadowsocks/password.key.age`

## Outcome

- Repo-managed service secrets now follow the same plaintext/encrypted naming
  convention as the key material under `data/secrets`.

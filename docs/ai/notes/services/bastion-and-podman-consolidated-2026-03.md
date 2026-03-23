# Bastion Services and Podman Compose Platform — Consolidated (2026-03)

## Scope

Canonical summary covering the Podman compose platform model, bastion-host
service migration, config centralization, secret injection, and systemd
lifecycle work completed in March 2026.

## Podman compose module model

- `services.podmanCompose.<stack>.instances` is the canonical instance shape.
- Stack-level path configuration uses `stackDir`.
- Instance definitions may be plain attrsets or functions receiving
  `{ stackName, instanceName, stackDir, workDir, user, uid, podmanSocket }`.
- `podmanSocket` is derived from the target user.
- If `source` is set and `entryFile` is unset, default to `compose.yml`.
- `entryFile` may be one file or an ordered list.

## File materialization

- Compose trees can be repo-managed with `source` plus `files`.
- Materialization is store-backed, binary-safe, recursive for directories, and
  preserves path context through direct Nix path interpolation.
- `extraFiles` was removed.
- Preferred source of truth is Nix attrsets rendered by the module, not manual
  YAML strings, unless a stack intentionally stays file-backed.

## Config centralization

- `services.podmanCompose.<stack>.instances.<name>.exposedPorts` is the source
  of truth for compose-managed host ports and firewall intent.
- `hosts/<bastion-host>/services.nix` owns per-instance port definitions.
- Live compose stacks remain file-backed under
  `hosts/<bastion-host>/compose/**`; generated `.env` files derive runtime
  values from `exposedPorts` and other instance metadata.
- `lib/podman.nix` opens compose-managed firewall ports from `exposedPorts`;
  `hosts/<bastion-host>/firewall.nix` should only keep non-compose and
  host-specific rules.

## Secret injection

- `envSecrets` is the supported file-backed secret mechanism.
- Schema: `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret`.
- Secrets are injected by bind-mounting files and generating wrapper/env-file
  wiring, not by copying plaintext env files into workdirs.
- Encrypted payloads use the `.key.age` suffix, aligned with
  `scripts/age-secrets.sh` expectations.
- `scripts/age-secrets.sh` covers all managed entries from
  `data/secrets/default.nix`, including `data/secrets/services/**/*.key.age`.

## Bastion service migration status

- `hosts/<bastion-host>/services.nix` is the repo-managed home for user-run
  compose stacks.
- Migrated stacks: `beszel`, `dockge`, `docmost`, `immich`.
- Active migrated secrets:
  - `beszel`: `KEY`, `TOKEN`
  - `docmost`: `APP_SECRET`, `DATABASE_URL`, `POSTGRES_PASSWORD`
  - `immich`: `DB_PASSWORD` / `POSTGRES_PASSWORD`
  - `shadowsocks`: `PASSWORD`
- `zulip` remains inactive and still needs secret migration before
  re-enablement.

## Systemd lifecycle

- Generated Podman user units are managed through `lib/systemd-user-manager.nix`
  bridge units so changes participate in old-stop/new-start behavior during
  `nixos-rebuild switch` and `test`.
- Bridge state lives under `/run/nixos/systemd-user-manager/` and is gated on
  user-manager availability.
- Changed active and failed units restart; changed inactive units stay inactive;
  newly bridged units start once on first activation.
- One reload unit per user manager so `systemctl --user daemon-reload` runs only
  once per user.

## Platform fixes

- Inline multiline `bash -c` payloads in generated user units replaced with
  store scripts to avoid `Unbalanced quoting` parse failures.
- Optional `WorkingDirectory = "-<path>"` avoids first-start `CHDIR` failures.
- Bridge stop-state detection keys off `ActiveState`, so failed user units are
  retried on rebuild while intentionally inactive units remain inactive.
- Stack-level tmpfiles provisioning creates roots user services cannot create
  themselves under `/var/lib`.

## Superseded notes

- `docs/ai/notes/services/bastion-compose-config-centralization-2026-03.md`
- `docs/ai/notes/services/bastion-service-migration-consolidated-2026-03.md`
- `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md`

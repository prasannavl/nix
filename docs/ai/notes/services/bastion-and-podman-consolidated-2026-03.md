# Bastion Services and Podman Compose Platform — Consolidated (2026-03)

## Scope

Canonical summary covering the Podman compose platform model, bastion-host
service migration, config centralization, secret injection, and systemd
lifecycle work completed in March 2026.

## Podman compose module model

- Shared implementation lives in `lib/podman.nix`.
- `services.podmanCompose.<stack>.instances` is the canonical instance shape.
- Stack-level path configuration uses `stackDir`.
- Stack-level defaults also include `user`, `servicePrefix`, and
  `nginxDefaultHost`.
- Instance definitions may be plain attrsets or functions receiving
  `{ stackName, instanceName, stackDir, workDir, user, uid, podmanSocket }`.
- `podmanSocket` is derived from the target user.
- If `source` is set and `entryFile` is unset, default to `compose.yml`.
- `entryFile` may be one file or an ordered list.
- Non-empty `services.podmanCompose` also enables Podman, enables
  `dockerCompat`, enables DNS on the default network, and installs both `podman`
  and `podman-compose`.

## Generated runtime model

- Each instance renders store-backed source files, then stages them into its
  working directory at service start.
- The main generated user unit is a stateless oneshot service:
  - `ExecStart`: `podman compose up -d --remove-orphans`
  - `ExecStop`: `podman compose down`
  - `ExecReload`: `down`, cleanup, restage files, then `up -d`
- Runtime manifests under `$XDG_RUNTIME_DIR/podman-compose/` track staged files
  so reload and stop can clean up only what the module materialized.
- Instance `serviceOverrides` are merged over the generated unit.
- Stack roots are created with tmpfiles so rootless user services can rely on
  working directories under `/var/lib`.

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
- `lib/podman.nix` derives firewall openings directly from `exposedPorts`
  entries where `openFirewall = true`.
- The same metadata is used to derive
  `services.podmanCompose.<stack>.nginxProxyVhosts` and
  `services.podmanCompose.<stack>.cloudflareTunnelIngress`.
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
- Each compose instance has three lifecycle tags with default `"0"`:
  - `bootTag`: forces `podman compose restart`
  - `recreateTag`: forces `podman compose up --force-recreate`
  - `imageTag`: forces `podman compose pull`
- Tag actions are stateless. They do not use stored tag files; instead they are
  modeled as separate user action units triggered through
  `lib/systemd-user-manager.nix` only when the corresponding tag value changes
  across generations for an already active compose service.
- If `imageTag` and `recreateTag` both change in one deploy, both action bridges
  fire; image refresh and recreate are separate actions attached to the same
  active compose service.

## What changes do

- Compose source/file/env-secret changes:
  - change the main generated user unit and restart stamp
  - active stacks restart through the standard bridge path
  - inactive stacks stay inactive
- `bootTag` change:
  - runs the generated `*-boot-tag.service`
  - attempts `podman compose restart`
  - falls back to `up -d --remove-orphans` if the stack has not been created yet
- `recreateTag` change:
  - runs the generated `*-recreate-tag.service`
  - uses `podman compose up --force-recreate`
- `imageTag` change:
  - runs the generated `*-image-tag.service`
  - uses `podman compose pull`
- Plain reboot:
  - does not replay lifecycle tags
  - only the main compose user unit starts

## Constraints

- Lifecycle tag actions only fire for stacks whose main user unit was active in
  the previous generation.
- A newly introduced non-default tag does not retroactively fire just because
  the tag unit appeared for the first time; it fires on subsequent tag changes.
- `imageTag` only refreshes pulled images. Build-only services may need an
  explicit build path if image refresh semantics need to cover them too.

## Platform fixes

- Inline multiline `bash -c` payloads in generated user units replaced with
  store scripts to avoid `Unbalanced quoting` parse failures.
- Optional `WorkingDirectory = "-<path>"` avoids first-start `CHDIR` failures.
- Bridge stop-state detection keys off `ActiveState`, so failed user units are
  retried on rebuild while intentionally inactive units remain inactive.
- Stack-level tmpfiles provisioning creates roots user services cannot create
  themselves under `/var/lib`.
- Podman compose `ExecStart` is stateless and uses `up -d --remove-orphans`.
- Boots do not replay lifecycle tags. Tag actions only happen on deploy-time
  bridge changes for already active services.

## Superseded notes

- `docs/ai/notes/services/bastion-compose-config-centralization-2026-03.md`
- `docs/ai/notes/services/bastion-service-migration-consolidated-2026-03.md`
- `docs/ai/notes/services/podman-compose-platform-consolidated-2026-03.md`

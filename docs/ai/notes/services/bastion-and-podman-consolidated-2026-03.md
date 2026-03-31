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
- Shared runtime shell lives in `lib/podman-compose/helper.sh`, while the Nix
  module in `lib/podman-compose/default.nix` owns metadata generation and unit
  wiring.
- The main generated user unit is a stateless long-running service:
  - `ExecStart`: `podman compose up -d --remove-orphans`, then
    `podman compose wait`
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

- Generated Podman user units are managed through the per-user reconciler in
  `lib/systemd-user-manager.nix` so changes participate in deploy-time
  user-manager reconciliation during `nixos-rebuild switch` and `test`.
- Reconciler state lives in the reconciler `StateDirectory`; user-identity
  restart stamps remain under `/run/nixos/systemd-user-manager/`.
- Changed active and failed units restart; inactive-but-startable units are
  started during reconcile; newly bridged units start once on first activation.
- One reload unit per user manager so `systemctl --user daemon-reload` runs only
  once per user.
- Each compose instance has three lifecycle tags with default `"0"`:
  - `bootTag`: marks the main compose unit changed so active stacks restart
  - `recreateTag`: marks the main compose unit changed and arms the next managed
    start/restart to use `podman compose up --force-recreate`
  - `imageTag`: runs `podman compose pull` as a transient pre-action
- Tag actions are stateless. They do not use stored tag files.
- `imageTag` and `recreateTag` are separate transient pre-actions; `bootTag` is
  folded into the main managed-unit restart trigger.

## What changes do

- Compose source/file/env-secret changes:
  - change the main generated user unit and restart stamp
  - active stacks restart through the standard bridge path
  - inactive-but-startable stacks are started during reconcile
- `bootTag` change:
  - changes the main generated user unit restart stamp
  - active stacks restart through the standard managed-unit path
- `recreateTag` change:
  - changes the main generated user unit restart stamp
  - runs a pre-action that arms the next managed start/restart to use
    `podman compose up --force-recreate`
- `imageTag` change:
  - runs a transient pre-action attached to the main managed unit
  - uses `podman compose pull`
  - active stacks then continue through the standard managed-unit path
- Plain reboot:
  - does not replay lifecycle tags
  - only the main compose user unit starts

## Runtime safety rules

- Reload performs cleanup plus restaging before `up -d`, so file-backed runtime
  trees are refreshed coherently instead of assuming old staged files are still
  valid.
- Staging must handle file-versus-directory conflicts cleanly when source shape
  changes across generations.
- Startup success is not "the compose command returned". The generated unit must
  fail fast when containers remain in bad non-running states such as `Created`.
- The long-running service model with `podman compose wait` is intentional so
  systemd can observe runtime failure and restart stacks on real failures.

## Restart Trigger Coverage

- `source` content is covered by the main restart stamp because the rendered
  store path for `compose.yml` changes when the source content changes.
- `files` content is covered for the same reason: rendered or copied store paths
  change when file-backed inputs change, and those paths are part of the restart
  stamp.
- Generated systemd unit structure is covered because the merged user unit
  definition is part of the restart stamp. That includes service environment,
  dependencies, and other unit-level wiring produced by the module.
- `envSecrets` mapping structure is covered. Adding, removing, or changing
  `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret` changes the restart
  stamp.
- `envSecrets` decrypted contents at a stable runtime path are not covered. If
  the secret file content rotates but the configured path stays the same, the
  restart stamp does not change, so reconcile can legitimately noop.

## Secret Rotation Caveat

- `envSecrets` files are restaged during `start`, `reload`, and `image-pull`.
- A pure secret-content rotation at the same path does not by itself force a
  managed-unit restart or restage.
- To force reconcile for that case, bump `bootTag` on the affected compose
  instance. Bumping `recreateTag` also changes the managed-unit stamp, but it
  additionally arms the next start to use `--force-recreate`.

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
- `docs/ai/notes/services/podman-compose-reload-staging-2026-03.md`
- `docs/ai/notes/services/podman-compose-runtime-path-conflicts-and-startup-readiness-2026-03.md`
- `docs/ai/notes/services/podman-compose-shell-helper-extraction-2026-03.md`
- `docs/ai/notes/services/podman-compose-start-state-verification-2026-03.md`
- `docs/ai/notes/services/podman-compose-wait-supervision-2026-03.md`

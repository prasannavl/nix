# Podman Compose Platform Consolidated Notes (2026-03)

## Scope

Canonical state for the March 2026 `services.podmanCompose` and
`systemd-user-manager` work: module shape, file materialization, secret
injection, unit lifecycle, and related platform fixes.

## Stable module model

- `services.podmanCompose.<stack>.instances` is the canonical instance shape.
- Stack-level path configuration uses `stackDir`.
- Instance definitions may be plain attrsets or functions receiving
  `{ stackName, instanceName, stackDir, workDir, user, uid, podmanSocket }`.
- `podmanSocket` is derived from the target user.
- If `source` is set and `entryFile` is unset, default to `compose.yml`.
- `entryFile` may be one file or an ordered list.

## File and source behavior

- Compose trees can be repo-managed with `source` plus `files`.
- Materialization is store-backed, binary-safe, recursive for directories, and
  preserves path context through direct Nix path interpolation.
- `extraFiles` is gone.
- Preferred source of truth is Nix attrsets rendered by the module, not manual
  YAML strings, unless a stack intentionally stays file-backed.

## Secret injection model

- `envSecrets` is the supported file-backed secret mechanism.
- Schema: `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret`.
- The older `.files` nesting was redundant and removed.
- Secrets are injected by bind-mounting files and generating wrapper/env-file
  wiring, not by copying plaintext env files into workdirs.

## Systemd lifecycle model

- Generated Podman user units are managed through `lib/systemd-user-manager.nix`
  bridge units so changes participate in old-stop/new-start behavior during
  `nixos-rebuild switch` and `test`.
- Bridge state lives under `/run/nixos/systemd-user-manager/` and is gated on
  user-manager availability.
- Changed active units restart, changed inactive units stay inactive, and newly
  bridged units start once on first activation.
- Emit one reload unit per user manager so `systemctl --user daemon-reload` only
  runs once per user.

## Platform fixes

- Inline multiline `bash -c` payloads in generated user units were replaced with
  store scripts to avoid `Unbalanced quoting` parse failures.
- Optional `WorkingDirectory = "-<path>"` avoids first-start `CHDIR` failures.
- Stack-level tmpfiles provisioning creates roots user services cannot create
  themselves under `/var/lib`.

## Superseded notes

- `docs/ai/notes/pvl-podman-compose-consolidated-2026-03.md`
- `docs/ai/notes/pvl-podman-compose-envsecrets-schema-simplification-2026-03-09.md`
- `docs/ai/notes/pvl-podman-compose-systemd-quoting-fix.md`
- `docs/ai/notes/pvl-podman-compose-user-unit-restart-on-switch.md`
- `docs/ai/notes/pvl-systemd-user-manager-consolidated-2026-03.md`
- `docs/ai/notes/pvl-x2-services-source-format-nix-attrs.md`
- `docs/ai/notes/pvl-x2-services-yaml-source-format.md`

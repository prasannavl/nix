# Podman Compose Platform Consolidated Notes (2026-03)

## Scope

Canonical state for the March 2026 `services.podmanCompose` and
`systemd-user-manager` work: module shape, file materialization, secret
injection, unit lifecycle, and related platform fixes.

## Stable module model

- `services.podmanCompose.<stack>.instances` is the canonical instance name.
- Stack-level path configuration uses `stackDir`.
- Instance definitions may be plain attrsets or functions receiving:
  `{ stackName, instanceName, stackDir, workDir, user, uid, podmanSocket }`.
- `podmanSocket` is derived from the target user.
- If `source` is set and `entryFile` is unset, `compose.yml` is the default
  entry file.
- `entryFile` may be a string or an ordered list.

## File and source behavior

- Compose trees can be defined with repo-managed `source` plus `files`.
- File materialization is store-backed and binary-safe.
- Directory paths expand recursively.
- Path context is preserved through direct Nix path interpolation.
- The temporary `extraFiles` split is gone.
- Canonical content format for repo-managed compose definitions is Nix attrsets
  rendered by the module, not hand-authored YAML strings.

## Secret injection model

- `envSecrets` is the supported file-backed secret mechanism.
- Current schema is: `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret`.
- The earlier `envSecrets.<composeService>.files.<ENV_VAR>` layer was removed as
  redundant.
- Secret injection works by bind-mounting files and generating wrapper/env-file
  wiring instead of copying plaintext env files into workdirs.

## Systemd lifecycle model

- Generated Podman user units are managed through `lib/systemd-user-manager.nix`
  bridge units so changed definitions participate in old-stop/new-start behavior
  during `nixos-rebuild switch` and `test`.
- Bridge behavior is gated on user-manager availability and stores transient
  state under `/run/nixos/systemd-user-manager/`.
- Changed active user units restart; changed inactive ones stay inactive; newly
  introduced bridged units start once on first activation.
- One reload unit is emitted per user manager so
  `systemctl --user daemon-reload` runs once per user.

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

# Podman Compose Shell Helper Extraction (2026-03)

## Context

`lib/podman-compose.nix` had accumulated several large generated shell scripts
for staging runtime files, cleanup, verification, supervision, reload, start,
stop, and image pulls.

That made the compose runtime flow harder to review and harder to lint with
normal shell tooling like `shellcheck`.

## Decision

- Move the module body to `lib/podman-compose/default.nix`.
- Extract the runtime shell logic to `lib/podman-compose/helper.sh`.
- Build the helper with `pkgs.writeShellApplication` so the checked-in shell can
  stay plain Bash while runtime tools are provided through explicit
  `runtimeInputs`.
- Pass per-instance runtime data through an explicit metadata JSON file exposed
  with `PODMAN_COMPOSE_METADATA`, plus small env vars like
  `PODMAN_COMPOSE_SERVICE_NAME`.

## Outcome

- `default.nix` now owns data modeling, service generation, and the metadata
  contract.
- `helper.sh` owns the runtime control flow for:
  - `link-files`
  - `cleanup-files`
  - `verify`
  - `monitor`
  - `reload`
  - `start`
  - `stop`
  - `image-pull`
- Compose service instances still stage runtime files under the working
  directory and track cleanup paths through the runtime manifest under
  `$XDG_RUNTIME_DIR/podman-compose/`.

## Follow-Up

- Keep future compose shell behavior changes in `helper.sh` unless the change
  needs new metadata or different systemd wiring.
- When the metadata contract changes, update both `default.nix` and `helper.sh`
  in the same change.

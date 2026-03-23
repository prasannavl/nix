# Nixbot Entrypoint and Packaging (2026-03)

## Entrypoint layout

- Canonical script source: `pkgs/nixbot/nixbot.sh`.
- Compatibility wrapper: `scripts/nixbot.sh` -- minimal handoff that resolves
  the target path and `exec`s into the real entrypoint. It does **not** call
  `ensure_runtime_shell`; the delegated entrypoint already owns runtime
  dependency setup and `nix shell` re-exec.
- The old name `scripts/nixbot-deploy.sh` is retired.

## CLI design

- Bare `nixbot` (no arguments) prints usage and exits 0 -- non-destructive and
  self-describing.
- `nixbot run` is the explicit full-workflow entrypoint (replaces the former
  implicit default / `run --action all` form).
- Operational modes are top-level actions: `deploy`, `build`, `tf`, `tf-dns`,
  `tf-platform`, `tf-apps`, `tf/<project>`, `check-bootstrap`.
- Dependency management: `deps` enters the pinned runtime shell; `check-deps`
  verifies the current environment without re-exec.
- `nixbot tofu ...` remains a separate local-only wrapper mode.

## Packaging model

- `pkgs/nixbot/flake.nix` is the package entrypoint.
- The Nix wrapper executes the package-owned script via `${pkgs.bash}/bin/bash`,
  supplies the runtime toolchain, and sets `NIXBOT_IN_NIX_SHELL=1` so the script
  does not try to derive a flake root from its Nix store path.
- `pkgs.nixbot` is available through the overlay for host installation; root
  flake consumers can run `nix run path:.#pkgs.<system>.nixbot -- ...`.
- Bastion forced-command ingress points directly at `${pkgs.nixbot}/bin/nixbot`
  -- no more copying a wrapper into `/var/lib/nixbot`.

## Wrapper exception (bash-patterns)

- Thin wrapper scripts that delegate to an entrypoint which already handles
  runtime setup may skip `ensure_runtime_shell`.
- This is recorded as an explicit exception in the Bash coding patterns so the
  rule stays visible without forcing redundant wrapper behavior.

## Superseded notes

- `script-entrypoint-rename-2026-03.md`
- `run-subcommand-default-usage-2026-03.md`
- `package-flake-wrapper-2026-03.md`
- `nixbot-wrapper-runtime-shell-exception-2026-03.md`

# Nixbot Package Flake Wrapper

- Date: 2026-03-21
- Scope: package `nixbot` as a repo-local flake app while preserving the bastion
  forced-command path contract

## Decision

- Add `pkgs/nixbot/flake.nix` as the package entrypoint for `nixbot`.
- Make `pkgs/nixbot/nixbot.sh` the canonical script source.
- Keep `scripts/nixbot.sh` only as a compatibility wrapper.
- Have the package wrapper execute the package-owned script via
  `${pkgs.bash}/bin/bash`.
- Have the package wrapper provide the runtime toolchain itself and set
  `NIXBOT_IN_NIX_SHELL=1` so the script does not try to derive a flake root from
  its Nix store path.
- Point bastion forced-command ingress directly at `${pkgs.nixbot}/bin/nixbot`
  instead of copying a wrapper into `/var/lib/nixbot`.

## Rationale

- This moves bastion installation onto the normal repo-local package path
  without forcing a full source-tree relocation in the same change.
- The deploy trust model stays the same because bastion still accepts only the
  fixed packaged `nixbot` command.
- Local repo workflows can adopt `nix run path:.#pkgs.<system>.nixbot -- ...`
  while direct `scripts/nixbot.sh` execution remains available as a thin
  compatibility path.

## Result

- `pkgs.nixbot` is available through the overlay for host installation.
- Root flake consumers can run `nix run path:.#pkgs.<system>.nixbot -- ...`.
- Bastion no longer copies a wrapper into `/var/lib/nixbot`; ingress now
  executes the packaged binary directly.

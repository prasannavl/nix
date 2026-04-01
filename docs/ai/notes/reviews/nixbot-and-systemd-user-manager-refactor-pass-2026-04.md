# nixbot and systemd-user-manager Refactor Pass (2026-04)

## Scope

Cleanup and simplification pass across:

- `pkgs/nixbot/nixbot.sh`
- `pkgs/nixbot/default.nix`
- `pkgs/nixbot/flake.nix`
- `lib/systemd-user-manager/helper.sh`
- `lib/systemd-user-manager/default.nix`

## Changes

- Cached prepared host age-identity material in `nixbot` deploy context so the
  resolved key file and checksum are computed once per prepared target instead
  of being re-resolved by deploy prechecks, injection, and activation-context
  visibility polling.
- Simplified host age-identity helpers to consume the cached file/checksum
  directly, shrinking helper signatures and removing duplicate secret-material
  resolution from dry-run and live paths.
- Reworked `systemd-user-manager` stop-phase metadata handling to parse new
  metadata once per dispatcher, build an in-memory stamp map, and avoid one `jq`
  selection per managed unit.
- Kept metadata parse failures explicit by routing stop-phase metadata reads
  through dedicated helpers instead of inline `jq` command substitutions.
- Collapsed small Nix duplication by reusing a single managed-user list and a
  shared `artifactValuesByName` mapper in
  `lib/systemd-user-manager/default.nix`.
- Removed `with pkgs;` from `pkgs/nixbot/default.nix` and used explicit package
  bindings instead; also trimmed a small package export duplication in
  `pkgs/nixbot/flake.nix`.

## Validation

- `bash -n lib/systemd-user-manager/helper.sh pkgs/nixbot/nixbot.sh`
- `shellcheck lib/systemd-user-manager/helper.sh pkgs/nixbot/nixbot.sh`
- `nix-instantiate --parse lib/systemd-user-manager/default.nix`
- `nix-instantiate --parse pkgs/nixbot/default.nix`
- `nix-instantiate --parse pkgs/nixbot/flake.nix`
- `nix build path:./pkgs/nixbot#run`

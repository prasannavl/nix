# Nixbot Remote Build Known Hosts Fix (2026-03-09)

## Problem

`scripts/nixbot-deploy.sh` prepares a per-target temporary `known_hosts` file
and exports it through `NIX_SSHOPTS` for `nixos-rebuild`.

When `DEPLOY_BUILD_HOST` is a third host (for example deploying `pvl-a1` while
building on `nixbot@pvl-x2`), that temp file previously only included the target
host key. `nixos-rebuild` reused the same `NIX_SSHOPTS` for the
`nix-copy-closure` hop to the build host, so SSH strict checking failed against
the build host.

## Resolution

- Added `ssh_host_from_target()` to normalize `user@host` build-host values.
- Updated `prepare_deploy_context()` so non-local, non-target build hosts are
  also added to the temporary `known_hosts` file when the script is managing
  host keys implicitly (`knownHosts = null`).

## Effect

Cross-host remote builds now work with the same strict-host-key model already
used for target hosts, without requiring the operator to pre-seed
`~/.ssh/known_hosts` for the build host.

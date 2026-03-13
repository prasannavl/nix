# Nixbot Runtime Shell Consolidation 2026-03

## Summary

Standardized `scripts/nixbot-deploy.sh` so it always re-execs into a single
`nix shell` runtime, instead of mixing host-installed commands with an
OpenTofu-only `nix shell` wrapper.

## What Changed

- Added an early self-reexec path guarded by `NIXBOT_DEPLOY_IN_NIX_SHELL=1`.
- The runtime shell resolves packages with `--inputs-from <repo-root>` so the
  command set is pinned to this repo's flake inputs rather than the host
  registry.
- The runtime shell now provides:
  - `age`
  - `git`
  - `jq`
  - `nixos-rebuild`
  - `openssh` (`ssh`, `scp`, `ssh-keygen`)
  - `opentofu` (`tofu`)
- Simplified the Terraform path to call `tofu` directly once inside that shell.

## Operational Notes

- `nix` itself is still expected so the initial `nix shell` can start.
- The script now has a more consistent runtime contract across deploy, bastion,
  and Terraform flows.
- When invoked as an SSH forced command (`SSH_ORIGINAL_COMMAND` is set), the
  wrapper now skips `--inputs-from` entirely and starts a plain
  `nix shell nixpkgs#...` runtime. That avoids coupling the ingress wrapper's
  install path to flake-root discovery while keeping normal local/repo-root runs
  pinned to repo inputs.

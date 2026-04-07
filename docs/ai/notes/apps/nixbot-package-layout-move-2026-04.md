# nixbot package layout move

- Date: 2026-04-08
- Scope: `pkgs/{manifest.nix,README.md}`, `pkgs/tools/nixbot`,
  `pkgs/cloudflare-apps/default.nix`, `scripts/nixbot.sh`, `README.md`,
  `docs/{deployment.md,nixbot-security-trust-model.md,incus-readiness.md}`

## Decision

Move the `nixbot` package source tree from `pkgs/nixbot` to `pkgs/tools/nixbot`,
while keeping the root flake package and app ID as `nixbot`.

## Notes

- The nested package move requires the child flake and package definition to
  walk up one additional directory when importing `lib/flake/pkg-helper.nix`.
- Repo scripts and internal `nixbot` self-reference paths that locate the
  packaged entrypoint should use `pkgs/tools/nixbot`.

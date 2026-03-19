# Cloudflare Apps Store Path Resolution (2026-03)

## Scope

Durable note for resolving Cloudflare Worker asset directories from repo-local
child flakes to their real Nix store build outputs at Terraform plan/apply
time.

## Decision

- `tf/modules/cloudflare/workers.tf` now resolves each assets directory through
  a helper script before handing it to the Cloudflare provider.
- If the configured path is a child app directory with `flake.nix`, Terraform
  asks Nix for `path:<dir>#build` and uses the returned `/nix/store/...`
  directory.
- Legacy `.../result` paths are also recognized when their parent directory has
  `flake.nix`; those paths are normalized to the same `#build` output.

## Result

- Worker tfvars can point at `../../pkgs/cloudflare-apps/<app>` instead of a
  repo-local `result` symlink.
- The provider receives a real build output directory rather than a
  symlink-to-directory root, which avoids the asset hashing failure seen for
  `llmug-hello`.

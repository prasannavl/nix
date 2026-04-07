# Cloudflare Apps Default-Nix Terraform Builds

- Date: 2026-04-08
- Scope: `tf/modules/cloudflare/scripts/worker-dir-nix-resolver.sh`, direct
  Wrangler helpers under `pkgs/cloudflare-apps/*`, root package manifest
  conventions

## Decision

For the Terraform apps workflow, package builds must go through
`--file <dir>/default.nix`. Child and root `flake.nix` wrappers are for
developer UX outside this workflow and should not be part of Terraform app build
resolution.

## Why

- The repo keeps package-local `default.nix` files directly evaluatable for
  `nix-build` compatibility.
- Terraform app preparation and asset resolution should use that canonical
  `default.nix` contract instead of any flake wrapper.
- This avoids pure flake path restrictions entirely in the Terraform workflow.

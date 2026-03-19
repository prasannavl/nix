# Cloudflare Apps

This directory holds repo-managed Cloudflare application source trees used by
`tf/cloudflare-apps`.

## Layout

- `pkgs/cloudflare-apps/flake.nix`: aggregate build/stage/deploy entrypoint for
  the whole `cloudflare-apps` Terraform phase
- `pkgs/cloudflare-apps/<app>/`: per-app source tree
- `pkgs/cloudflare-apps/<app>/flake.nix`: optional per-app build/stage helper
  when that app needs a generated local path such as a `result` symlink

## Conventions

- `tf/*-apps` projects may have a matching package namespace at
  `pkgs/<project>/flake.nix`.
- `scripts/nixbot-deploy.sh` prepares those projects generically by running
  `nix run path:pkgs/<project>#stage` before OpenTofu plan/apply.
- For `tf/cloudflare-apps`, that means `pkgs/cloudflare-apps/flake.nix` is the
  single aggregate entrypoint.
- Source-only apps can live under `pkgs/cloudflare-apps/<app>/` without a child
  `flake.nix` if they do not need a pre-Terraform stage step.
- Apps with generated assets should expose at least `packages.build` and
  `packages.stage`, and may also expose app-local helpers such as
  `wrangler-deploy`.
- App-local Terraform deploy entrypoints are intentionally omitted; Terraform
  reconciliation stays aggregate at the `cloudflare-apps` project level.

## Examples

- `nix build .#pkgs.x86_64-linux.cloudflare-apps`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.stage`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.deploy -- --dry`
- `nix build .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello.stage`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello.wrangler-deploy`

## Terraform inputs

Worker/app definitions are referenced from `tf/cloudflare-apps/*.auto.tfvars` or
encrypted tfvars files under `data/secrets/tf/cloudflare/workers/`.

Minimal `tf/cloudflare-apps/workers.auto.tfvars` example:

```hcl
workers = {
  example-worker = {
    compatibility_date = "2026-03-15"
    main_module        = "src/index.js"

    modules = [
      {
        name         = "src/index.js"
        content_file = "../pkgs/cloudflare-apps/example-worker/src/index.js"
        content_type = "application/javascript+module"
      }
    ]
  }
}
```

Assets-only Workers are also supported:

```hcl
workers = {
  static-site = {
    compatibility_date = "2026-03-15"
    assets = {
      directory = "../pkgs/cloudflare-apps/static-site/assets"
      config = {
        run_worker_first = false
      }
    }
  }
}
```

For result-backed child flakes under `pkgs/cloudflare-apps/*`, the aggregate
`pkgs/cloudflare-apps/flake.nix` `stage` step now calls each child app's
`#stage` helper before OpenTofu runs.

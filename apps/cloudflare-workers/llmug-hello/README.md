# llmug-hello

This directory now contains the actual repo-local source for the `llmug-hello`
assets-only Cloudflare Worker.

Layout:

- source files at repo root: `index.html`, `favicon.ico`, `css/`, `js/`,
  `icons/`
- Cloudflare config: `wrangler.jsonc`
- local build output deployed by Terraform: `dist/`

Build flow:

- `make build` recreates `dist/`
- `tf/cloudflare-apps` deploys the Worker from `dist/`
- local worker flake: `apps/cloudflare-workers/llmug-hello/flake.nix`
- inside `apps/cloudflare-workers/llmug-hello/`, plain `nix build` builds the
  static output in the Nix store once this worker directory is tracked by Git
- inside `apps/cloudflare-workers/llmug-hello/`, `nix develop` provides `make`,
  `biome`, `wrangler`, and a `wrangler2` compatibility wrapper for the existing
  Makefile
- before the worker directory is tracked by Git, use `nix build path:.`
- inside `apps/cloudflare-workers/llmug-hello/`,
  `nix run path:.#deploy -- --dry` rebuilds, syncs the result into local
  `dist/`, and then runs `scripts/nixbot-deploy.sh --action tf-apps --dry`
- root flake re-exports these as
  `path:.#apps.cloudflare-workers.llmug-hello.build` and
  `path:.#apps.cloudflare-workers.llmug-hello.deploy`
- legacy flat aliases `path:.#llmug-hello-build` and `path:.#llmug-hello-deploy`
  still exist for compatibility

The Worker definition is in:

- `data/secrets/tf/cloudflare/workers/stage.tfvars.age`

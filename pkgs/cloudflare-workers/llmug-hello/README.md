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
- local worker flake: `pkgs/cloudflare-workers/llmug-hello/flake.nix`
- inside `pkgs/cloudflare-workers/llmug-hello/`, plain `nix build` builds the
  static output in the Nix store once this worker directory is tracked by Git
- inside `pkgs/cloudflare-workers/llmug-hello/`, `nix develop` provides `make`,
  `biome`, `wrangler`, and a `wrangler2` compatibility wrapper for the existing
  Makefile
- before the worker directory is tracked by Git, use `nix build path:.`
- inside `pkgs/cloudflare-workers/llmug-hello/`,
  `nix run path:.#deploy -- --dry` rebuilds, syncs the result into local
  `dist/`, and then runs `scripts/nixbot-deploy.sh --action tf-apps --dry`
- root flake exports the build as
  `.#pkgs.x86_64-linux.cloudflare-workers.llmug-hello` and the deploy
  installable as `.#pkgs.x86_64-linux.cloudflare-workers.llmug-hello.deploy`

The Worker definition is in:

- `data/secrets/tf/cloudflare/workers/stage.tfvars.age`

# Pkgs

This directory holds repo-local runnable package source trees.

Each package owns its own local `flake.nix`. `pkgs/default.nix` auto-discovers
child flakes and aggregates them into the root flake's custom nested
`pkgs.<system>.*` installables while also exposing overlay packages directly as
`pkgs.<name>`.

To add a new package, create `pkgs/<name>/flake.nix` with `packages.default`. If
you want extra root-flake entrypoints such as `nix run .#pkgs.<name>.deploy`,
expose them as derivation aliases under `packages` too, for example
`packages.deploy = deploy;`.

## Current Examples

- `pkgs/hello-rust/`: minimal Rust hello-world application
- `pkgs/cloudflare-apps/`: aggregate package namespace for the
  `tf/cloudflare-apps` phase
- `pkgs/cloudflare-apps/<app>/`: repo-managed Cloudflare app source trees

## Root Flake Examples

- `nix build .#pkgs.x86_64-linux.hello-rust`
- `nix run .#pkgs.x86_64-linux.hello-rust`
- `nix build .#pkgs.x86_64-linux.cloudflare-apps`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.deploy -- --dry`
- `nix build .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello.wrangler-deploy`

Inside a child directory, `path:.` still uses the working tree directly while
plain `.` uses the Git snapshot.

Overlay package example:

- `pkgs."hello-rust"`

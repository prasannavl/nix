# Pkgs

This directory holds repo-local runnable package source trees.

Each package owns its own local `flake.nix`. `pkgs/default.nix` auto-discovers
child flakes and aggregates them into the root flake's custom nested
`pkgs.<system>.*` installables while also exposing overlay packages directly as
`pkgs.<name>`.

To add a new package, create `pkgs/<name>/flake.nix` with `packages.default`. If
you want extra root-flake entrypoints such as `nix run .#pkgs.<name>.deploy`,
expose them as derivation aliases under `packages` too, for example
`packages.deploy = deploy;`. Child-local `apps.*` can still exist when they are
useful inside the child flake itself.

Current examples:

- `pkgs/hello-rust/`: minimal Rust hello-world application
- `pkgs/cloudflare-workers/<worker>/`: repo-managed Cloudflare Worker source
  trees used by `tf/cloudflare-apps`

Root flake examples:

- `nix build .#pkgs.x86_64-linux.hello-rust`
- `nix run .#pkgs.x86_64-linux.hello-rust`
- `nix build .#pkgs.x86_64-linux.cloudflare-workers.llmug-hello`
- `nix run .#pkgs.x86_64-linux.cloudflare-workers.llmug-hello.deploy -- --dry`

Inside a child directory, `path:.` still uses the working tree directly while
plain `.` uses the Git snapshot.

Overlay package example:

- `pkgs."hello-rust"`

# Apps

This directory holds repo-local runnable application source trees.

Each app should own its own local `flake.nix`. `apps/default.nix` pulls those
together for the root flake and also exposes host-installable packages through
the overlay namespace.

`apps/default.nix` now auto-discovers nested child flakes. To add a new app,
create `apps/<name>/flake.nix` with `packages.default` and `apps.default`, plus
any optional aliases like `packages.build` or `apps.run`.

Current example:

- `apps/hello-rust/`: minimal Rust hello-world application
- `apps/cloudflare-workers/<worker>/`: repo-managed Cloudflare Worker source
  trees used by `tf/cloudflare-apps`

Root flake installables mirror the directory shape:

- `nix run path:.#apps.hello-rust`
- `nix build path:.#apps.hello-rust.build`
- `nix run path:.#apps.hello-rust.run`

`nix run .#apps.hello-rust` works too once the `apps/` tree is tracked by Git.
Plain `.` flakes use the Git snapshot, so untracked files only appear through
`path:.`.

Overlay package example:

- `pkgs.apps."hello-rust"`

# Examples Folder Layout

## Scope

- Move the repo's `hello-*` sample projects under `pkgs/examples/`.

## Decisions

- The sample projects now live at:
  - `pkgs/examples/edi-ast-parser-rs`
  - `pkgs/examples/hello-go`
  - `pkgs/examples/hello-node`
  - `pkgs/examples/hello-python`
  - `pkgs/examples/hello-rust`
  - `pkgs/examples/hello-web-static`
- Root flake package names are prefixed to make examples explicit:
  - `example-edi-ast-parser-rs`
  - `example-hello-go`
  - `example-hello-node`
  - `example-hello-python`
  - `example-hello-rust`
  - `example-hello-web-static`
- Package docs should refer to the new example paths where they name a concrete
  reference package.

## Files

- `lib/flake/packages.nix`
- `pkgs/README.md`
- `README.md`
- `docs/services.md`

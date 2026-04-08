# Pkgs

This directory holds repo-local runnable package source trees.

Canonical package definitions live in package-local `default.nix` files and are
composed centrally through `lib/flake/packages.nix`.

Child `flake.nix` files are wrapper flakes for local developer UX such as
package-local `nix run` / `nix develop`.

The root flake now exports repo-local package installables directly from the
central package tree in `lib/flake/packages.nix`, not by auto-discovering child
wrapper flakes.

To add a new package:

- create a package-local `default.nix` under `pkgs/` as the canonical package
  definition
- add it to `lib/flake/packages.nix`
- optionally add a package-local `flake.nix` as a wrapper flake for local UX and
  focused local commands
- if you want extra root-flake entrypoints such as `nix run .#<name>`, expose
  them from the canonical package tree in `lib/flake/packages.nix`

Example projects live under `pkgs/examples/`. Their root flake package names are
prefixed with `example-`.

## Current Examples

- `pkgs/examples/hello-python/`: minimal Python hello-world package built from a
  `pyproject.toml` with a local wrapper flake and dev shell
- `pkgs/examples/hello-go/`: minimal Go hello-world package built with
  `buildGoModule` plus a local wrapper flake and dev shell
- `pkgs/examples/hello-node/`: minimal Node.js hello-world package built with
  `buildNpmPackage` plus a local wrapper flake and dev shell
- `pkgs/examples/hello-rust/`: minimal Rust hello-world package with local
  wrapper flake
- `pkgs/examples/hello-web-static/`: static web asset package for host or
  service reuse with a local wrapper flake and dev shell
- `pkgs/tools/nixbot/`: deploy package and local wrapper flake
- `pkgs/cloudflare-apps/`: aggregate package namespace for the
  `tf/cloudflare-apps` phase
- `pkgs/cloudflare-apps/<app>/`: repo-managed Cloudflare app source trees

## Root Flake Examples

- `nix build .#example-hello-python`
- `nix run .#example-hello-python`
- `nix build .#example-hello-go`
- `nix run .#example-hello-go`
- `nix build .#example-hello-node`
- `nix run .#example-hello-node`
- `nix build .#example-hello-rust`
- `nix run .#example-hello-rust`
- `nix build .#example-hello-web-static`
- `nix run .#nixbot -- --help`
- `nix build .#cloudflare-apps`
- `nix run .#cloudflare-apps-deploy -- --dry`

Inside a child directory, plain `.` uses the child flake directly.

Overlay package example:

- `pkgs."example-hello-rust"`

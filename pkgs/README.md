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

- create `pkgs/<name>/default.nix` as the canonical package definition
- add it to `lib/flake/packages.nix`
- optionally add `pkgs/<name>/flake.nix` as a wrapper flake for local UX and
  focused local commands
- if you want extra root-flake entrypoints such as
  `nix run .#pkgs.<name>.deploy`, expose them from the canonical package tree in
  `lib/flake/packages.nix`

## Current Examples

- `pkgs/hello-python/`: minimal Python hello-world package built from a
  `pyproject.toml` with a local wrapper flake and dev shell
- `pkgs/hello-go/`: minimal Go hello-world package built with `buildGoModule`
  plus a local wrapper flake and dev shell
- `pkgs/hello-node/`: minimal Node.js hello-world package built with
  `buildNpmPackage` plus a local wrapper flake and dev shell
- `pkgs/hello-rust/`: minimal Rust hello-world package with local wrapper flake
- `pkgs/hello-web-static/`: static web asset package for host or service reuse
  with a local wrapper flake and dev shell
- `pkgs/nixbot/`: deploy package and local wrapper flake
- `pkgs/cloudflare-apps/`: aggregate package namespace for the
  `tf/cloudflare-apps` phase
- `pkgs/cloudflare-apps/<app>/`: repo-managed Cloudflare app source trees

## Root Flake Examples

- `nix build .#pkgs.x86_64-linux.hello-python`
- `nix run .#pkgs.x86_64-linux.hello-python`
- `nix build .#pkgs.x86_64-linux.hello-go`
- `nix run .#pkgs.x86_64-linux.hello-go`
- `nix build .#pkgs.x86_64-linux.hello-node`
- `nix run .#pkgs.x86_64-linux.hello-node`
- `nix build .#pkgs.x86_64-linux.hello-rust`
- `nix run .#pkgs.x86_64-linux.hello-rust`
- `nix build .#pkgs.x86_64-linux.hello-web-static`
- `nix run .#pkgs.x86_64-linux.nixbot -- --help`
- `nix build .#pkgs.x86_64-linux.cloudflare-apps`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.deploy -- --dry`
- `nix build .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello.wrangler-deploy`

Inside a child directory, `path:.` still uses the working tree directly while
plain `.` uses the Git snapshot.

Overlay package example:

- `pkgs."hello-rust"`

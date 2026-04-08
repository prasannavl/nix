# Docs Command Shortening And README Contributing

- Updated Markdown docs to prefer root-exported flake installables like
  `nix build .#example-hello-python` and `nix run .#lint` instead of longer
  system-qualified or `path:`-qualified forms where the root export already
  exists.
- Kept package-local child-flake commands for package-owned app entrypoints that
  are not exported as root apps, such as package-local `#dev` or
  `#wrangler-deploy`.
- Added a contributing section to `README.md` documenting
  `./scripts/git-install-hooks.sh`, `nix fmt`, `nix run .#lint`, and the
  rationale for the diff-scoped `pre-push` hook instead of a `pre-commit` hook.

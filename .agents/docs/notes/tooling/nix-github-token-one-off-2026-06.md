# One-Off GitHub Token For Nix

Use a local `NIX_CONFIG` override when a Nix command may need GitHub API quota
or private GitHub access, but the token must not be written into the repo:

```bash
NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update
```

Replace `nix flake update` with the actual command being run, for example
`nix build .`, `nix develop`, or `nix flake check`.

This is intentionally non-invasive:

- The token is supplied by the local shell environment for only that process.
- No flake input, module, script, or repo config should embed the token.
- The repo's Nix validation-source rule still applies: use `.` from the repo
  root, an absolute repo path without a `path:` prefix from outside the repo, or
  an intentional `git+file:///...` ref for committed snapshots.

For persistent local use, prefer a private user-level Nix config such as
`~/.config/nix/nix.conf`, not a repo file.

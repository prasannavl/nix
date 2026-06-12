# Nixbot Repo-Relative Secret Paths

## Scope

Records the June 2026 deploy regression where SSH fallback paths resolved
`data/secrets/...` under `hosts/data/...` after a transient transport failure.

## Finding

- `hosts/nixbot.nix` defines deploy, bootstrap, proxy-hop, and host age identity
  secret paths as repo-root-relative strings such as
  `data/secrets/globals/nixbot/nixbot.key.age`.
- `hosts/nixbot.override.nix` is a partial machine-local overlay; it should not
  change the base directory for repo-owned secret paths.
- Fallback paths like bootstrap key injection and proxy-hop SSH context setup
  can resolve keys after the current directory has changed or after a retry has
  re-entered setup. These paths must not depend on process CWD.

## Durable Rule

Nixbot host workflows run from the prepared repo worktree. The machine-local
override path may remain absolute to the operator checkout, but it should only
participate in config evaluation and must not rebase repo-owned secret strings.

Relative key lookup should stay simple:

- current working directory first, normally the prepared repo worktree;
- config directory for explicit config-local key material;
- config directory parent for repo-root-relative paths from `hosts/nixbot.nix`.

## Source Of Truth Files

- `pkgs/tools/nixbot/nixbot.sh`
- `hosts/nixbot.nix`
- `hosts/nixbot.override.nix`

# `age-secrets.sh` Default Scope Expansion (2026-03-09)

## Context

- `scripts/age-secrets.sh` discovered managed files by filtering
  `data/secrets/default.nix` to a single target directory.
- Its default target directory was `data/secrets`, so repo-managed encrypted
  service secrets under `data/secrets/services/**/*.key.age` were skipped
  unless the caller explicitly passed `data/secrets/services`.

## Decision

- Change the default run scope to all managed entries from
  `data/secrets/default.nix`.
- Preserve the optional `[dir]` argument so callers can still restrict runs to a
  managed subtree.

## Outcome

- `scripts/age-secrets.sh`, `scripts/age-secrets.sh encrypt`, and
  `scripts/age-secrets.sh decrypt` now include both the core
  `data/secrets/**` keys and the managed service entries under
  `data/secrets/services/**` by default.

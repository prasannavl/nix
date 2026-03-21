# Worktree Terraform Lockfile Regression (2026-03)

## Scope

Explain the Terraform failure that appeared after `nixbot-deploy` switched to
per-run detached Git worktrees.

## Findings

- `scripts/nixbot.sh` correctly runs `tofu init -lockfile=readonly` in each
  project so deploy runs do not mutate committed lockfiles.
- The three committed Cloudflare OpenTofu lockfiles under `tf/` contained both
  the current provider address `registry.opentofu.org/cloudflare/cloudflare` and
  a stale legacy address `registry.opentofu.org/hashicorp/cloudflare`.
- Earlier non-worktree runs could mask this because an already-populated local
  `.terraform/providers` tree still satisfied the stale lock entry.
- Fresh detached worktrees start with a clean provider cache inside the project,
  so readonly init cannot repair the duplicated provider address and later plan
  fails with `Required plugins are not installed`.

## Resolution

- Normalize the committed lockfiles so they record the actual required provider
  set: `cloudflare/cloudflare` plus `hashicorp/external`, with no stale
  `hashicorp/cloudflare` entry.
- Keep `-lockfile=readonly` in deploy automation; the bug was stale lockfile
  state, not the worktree design.

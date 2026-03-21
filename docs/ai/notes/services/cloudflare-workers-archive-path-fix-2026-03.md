# Cloudflare Workers Archive Path Fix (2026-03)

## Scope

Document the `tf-apps` deploy failure caused by stale archive worker source
paths after the repo layout standardized on `pkgs/cloudflare-apps/`.

## Findings

- `data/secrets/tf/cloudflare/workers/archive.tfvars` still referenced
  `../../pkgs/cloudflare-workers/...` for the `priyasuyash` and `openseal`
  Workers.
- The repo no longer has a `pkgs/cloudflare-workers/` tree; Worker source now
  lives under `pkgs/cloudflare-apps/<app>/`.
- `tf/modules/cloudflare/workers.tf` resolves each `modules[*].content_file`
  relative to `path.root` and OpenTofu hashes those files during planning, so
  stale paths fail before apply with `Error computing SHA-256 hash`.
- Fresh `nixbot-deploy` worktrees under `/dev/shm/.../repo` exposed this
  immediately because those detached checkouts only contain the current repo
  layout.

## Resolution

- Update the archive worker tfvars entries from `pkgs/cloudflare-workers` to
  `pkgs/cloudflare-apps`.
- Re-encrypt the matching `.tfvars.age` file after editing the plaintext source.

## Operational rule

- When repo layout changes move Worker source directories, update both the
  public/plaintext tfvars authoring file and its encrypted `.age` counterpart so
  deploy runs do not continue using stale paths.

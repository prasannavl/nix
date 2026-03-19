# Cloudflare Apps Package Runtime And Age Fallback (2026-03)

## Scope

Durable notes for the March 2026 refactor of the `nixbot` Terraform apps phase
and its bastion-side age decrypt behavior.

Historical note: the `stage` model described below was later replaced by the
build-only flow documented in
`docs/ai/notes/nixbot/cloudflare-apps-stage-cleanup-2026-03.md`.

## Context

- `tf/*-apps` phases can depend on repo-local generated assets that are not
  checked into Git.
- The original fix for `tf/cloudflare-apps` staged `llmug-hello/result` as a
  symlink to the store, but that needed to be generalized beyond a one-off path.
- Bastion-side Terraform runtime secrets under `data/secrets/cloudflare/*.key.age`
  are encrypted for the machine age identity at `/var/lib/nixbot/.age/identity`,
  while many Cloudflare `*.tfvars.age` files are also decryptable with the
  deploy SSH key.

## Decision

- `scripts/nixbot-deploy.sh` now treats apps runtime preparation generically:
  if `pkgs/<project>/flake.nix` exists for a `tf/*-apps` project, it runs
  `nix run path:pkgs/<project>#stage` before OpenTofu.
- `pkgs/cloudflare-apps/flake.nix` is now the aggregate package entrypoint for
  `tf/cloudflare-apps` and orchestrates child app flakes such as
  `pkgs/cloudflare-apps/llmug-hello/flake.nix` by calling each child app's
  `#stage` helper.
- Child app flakes keep build/stage logic local, but Terraform deploy remains
  aggregate at the project level.
- Runtime decrypt identity selection now uses the shared candidate list for all
  `*.age` files.
- Per-identity decrypt failures are buffered and only printed if every
  candidate identity fails, which keeps successful fallback decrypts quiet.

## Result

- `tf-apps` build/stage behavior is now organized under `pkgs/<project>/` rather
  than hardcoded as a Cloudflare-specific one-off in the deploy script.
- `pkgs/cloudflare-workers` is retained only as a compatibility symlink; the
  primary namespace is now `pkgs/cloudflare-apps`.
- Bastion logs should stop showing repeated `age: error: no identity matched`
  lines for successful decrypt fallbacks, because per-identity `age` stderr is now
  buffered and only emitted if every candidate identity fails.

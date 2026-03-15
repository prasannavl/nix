# Nixbot GitHub Actions Runtime Warmup And Cache 2026-03

## Summary

Moved the noisy first-run `nix shell` closure fetch out of the `Remote action`
step in `.github/workflows/nixbot.yaml` and enabled cache reuse across GitHub
workflow runs.

## What Changed

- Added a GitHub Actions Nix cache step after Nix installation.
- Configured that cache step to use GitHub Actions cache only, with FlakeHub
  caching disabled.
- Added a dedicated warm-up step that calls
  `./scripts/nixbot-deploy.sh --ensure-deps >/dev/null` so the script itself
  remains the single source of truth for the runtime package set while exposing
  an explicit dependency-warmup mode.
- Kept the actual deploy behavior unchanged; only the timing and placement of
  the closure fetch moved.

## Operational Notes

- The first run after a cache miss will still need to fetch the closure, but it
  will happen in the warm-up step instead of inside `Remote action`.
- Subsequent runs can reuse the cached store paths, reducing both startup time
  and log noise in the deploy step.
- This workflow does not rely on FlakeHub login for cache reuse; it keeps the
  cache on the GitHub Actions backend instead.
- The large AWS dependency chain observed in the closure comes from the packaged
  `nix` runtime, not from `opentofu`. On this machine,
  `nix-store -q --tree /nix/store/qd67vi2j6q7skvwqnypd3jlgk6p37pfr-nix-2.31.2`
  shows `nix -> nix-store -> aws-sdk-cpp`.
- No secret file contents were read during this task.

# GCP Platform Phase Disabled

Date: 2026-03-21

- `scripts/nixbot.sh` no longer includes `gcp-platform` in the default
  `TF_PROJECT_NAMES` list.
- Result: `--action all` and `--action tf-platform` now run only the currently
  enabled platform projects instead of requiring GCP backend runtime state.
- Direct per-project runs remain available via `--action tf/gcp-platform` when
  GCP Terraform needs to be executed intentionally.

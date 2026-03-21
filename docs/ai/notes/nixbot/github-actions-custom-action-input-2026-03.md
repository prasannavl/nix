# GitHub Actions Custom Action Input

Date: 2026-03-21

- The deploy script already supports arbitrary configured Terraform project
  actions via `--action tf/<project>`.
- `.github/workflows/nixbot.yaml` should keep the normal deploy actions as a
  fixed dropdown for ergonomics.
- The GitHub workflow remains intentionally narrower than the deploy script and
  exposes only the standard deploy and Terraform phase actions.
- Validation remains centralized in `scripts/nixbot-deploy.sh`, which already
  rejects unsupported actions.

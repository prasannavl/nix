# nixbot GitHub Actions Tailscale OAuth Migration

## Context
- Task: update GitHub CI workflow to use Tailscale OAuth credentials instead of deprecated auth key input.
- Workflow: `.github/workflows/nixbot.yaml`.

## Changes
- Replaced `authkey: ${{ secrets.TAILSCALE_AUTHKEY }}` with:
  - `oauth-client-id: ${{ secrets.TAILSCALE_OAUTH_CLIENT_ID }}`
  - `oauth-secret: ${{ secrets.TAILSCALE_OAUTH_SECRET }}`
- Added required OAuth tag for node identity in the action config:
  - `tags: tag:ci`
- Upgraded action pin from `tailscale/github-action@v3` to `tailscale/github-action@v4`.
- Kept existing action args:
  - `args: --accept-routes`
- Added CI diagnostics flow for failed Tailscale connects:
  - Added `Verify Tailscale OAuth secrets in CI` preflight step to mint an OAuth access token using GitHub secrets and print token endpoint HTTP status for fast credential/context verification.
  - Kept `tailscale/github-action@v4` as the connection mechanism.
  - Added action inputs to avoid stale client/cache behavior while debugging OAuth login failures:
    - `version: latest`
    - `use-cache: "false"`
  - Removed `args: --accept-routes` because the action already includes `--accept-routes` internally.
  - Added a generated per-run hostname and passed it to the action:
    - format: `gh-nixbot-YYYYMMDD-<run_number>ts`
    - exported via `GITHUB_ENV` as `TS_HOSTNAME`
    - used in action input `hostname: ${{ env.TS_HOSTNAME }}`

## Follow-up
- Ensure repository/environment secrets exist:
  - `TAILSCALE_OAUTH_CLIENT_ID`
  - `TAILSCALE_OAUTH_SECRET`
- Ensure the OAuth client is allowed to issue `tag:ci` in tailnet ACL/tag owners.

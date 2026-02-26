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
  - `Connect to Tailscale` now has `id: tailscale` and `continue-on-error: true`.
  - Added `Collect Tailscale diagnostics on failure` step with explicit per-command output + exit codes (no grouped logs) to avoid hidden/empty diagnostics in GitHub UI.
  - Diagnostics now include:
    - runner identity/environment details
    - `sudo -n` availability checks
    - tailscale binary/version checks
    - `tailscale status`, `tailscale ip`, and `tailscale netcheck`
    - `journalctl -u tailscaled` and syslog grep output
    - process list and log-file discovery in `/tmp`, `/var/log`, and `${RUNNER_TEMP}`
  - Added explicit failure step so job still fails after logs are captured.
  - Guarded deploy step with `if: steps.tailscale.outcome == 'success'`.

## Follow-up
- Ensure repository/environment secrets exist:
  - `TAILSCALE_OAUTH_CLIENT_ID`
  - `TAILSCALE_OAUTH_SECRET`
- Ensure the OAuth client is allowed to issue `tag:ci` in tailnet ACL/tag owners.

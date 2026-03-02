# nixbot GitHub Actions Tailscale OIDC Migration

## Context

- Task: update GitHub CI workflow to use Tailscale trust credentials (OIDC
  federation) instead of deprecated auth key input.
- Workflow: `.github/workflows/nixbot.yaml`.

## Changes

- Replaced `authkey: ${{ secrets.TAILSCALE_AUTHKEY }}` with OIDC action inputs:
  - `oauth-client-id: ${{ secrets.TAILSCALE_OAUTH_CLIENT_ID }}`
  - `audience: ${{ secrets.TAILSCALE_OIDC_AUDIENCE }}`
- Added required OAuth tag for node identity in the action config:
  - `tags: tag:ci`
- Upgraded action pin from `tailscale/github-action@v3` to
  `tailscale/github-action@v4`.
- Added workflow permission required for GitHub OIDC token minting:
  - `permissions.id-token: write`
- Added generated per-run hostname passed to the action:
  - format: `gh-nixbot-<run_number>ts`
  - exported via `GITHUB_ENV` as `TS_HOSTNAME`
  - used in action input `hostname: ${{ env.TS_HOSTNAME }}`

## Follow-up

- Ensure repository/environment secrets exist:
  - `TAILSCALE_OAUTH_CLIENT_ID`
  - `TAILSCALE_OIDC_AUDIENCE`
- Ensure the Tailscale trust credential (OIDC) is configured for GitHub issuer
  and matching subject for this repo/environment.
- Ensure `tag:ci` is allowed for this trust credential in Tailscale policy/tag
  owners.

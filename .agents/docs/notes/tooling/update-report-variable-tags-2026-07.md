# Update Report Variable Tags

## Scope

Records the July 2026 `scripts/update.sh --report` fix for report-only updater
behavior and Podman image tags that come from Compose variable expansion.

## Findings

- `lib/ext/gnome-ext/update.sh` did not accept `--report`, so the top-level
  update report printed `Unknown argument: --report` under `lib/ext:` and exited
  non-zero even though other report sections continued.
- The Podman image reporter split image references at the last colon. Compose
  tags such as `ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}`
  were therefore parsed at the shell-parameter default delimiter and rendered as
  malformed `${IMMICH_VERSION: -release}` tags.
- Immich itself is not a comparable image-version case while it uses
  `IMMICH_VERSION=release`. The report should make that uncertainty explicit
  instead of marking the image as latest.

## Behavior

- GNOME extension updater report mode prints `p7-borders` and `p7-cmds` current
  versus latest versions without fetching hashes or editing package files.
- Podman image reporting ignores colons inside `${...}` shell parameter
  expansions when finding the Docker tag separator.
- Tags containing `$` are reported as `[variable tag]`. Literal `release` tags
  are reported as `[floating tag]`.

## Follow-up

- Immich should expose a concrete app image tag in the Nix compose source rather
  than the upstream Compose `${IMMICH_VERSION:-release}` indirection. Keep
  `immich-server` and `immich-machine-learning` on the same `immichVersion`
  binding so update reporting compares both image tags normally.
- Immich's GHCR image packages have very large tag histories. Use the upstream
  GitHub latest-release tag for `immich-server` and `immich-machine-learning`
  update comparisons, then fall back to normal registry tags for other images.
- Keep the local compose source aligned with the latest upstream service images
  and sidecar service definitions, but preserve local runtime ownership: systemd
  manages restarts, `envSecrets` injects database passwords, and the compose
  services keep explicit `user: 0:0`.

## VS Code

- `https://update.code.visualstudio.com/api/update/linux-x64/stable/latest` is
  an update-offer/download feed and can lag the published stable release list.
  On July 12, 2026 it still returned `1.127.0` while
  `https://update.code.visualstudio.com/api/releases/stable` listed `1.128.0`
  first.
- The VS Code updater should resolve the target version from
  `/api/releases/stable` and map it to the aligned commit from
  `/api/commits/stable/linux-x64`. Use the commit-specific download endpoints
  for artifact names and hashes.

## Validation

- `bash -n scripts/update.sh lib/ext/gnome-ext/update.sh`
- `python3 -m unittest discover -s scripts/support/tests`
- `./scripts/update.sh --only-ext-gnome-ext --report --color=never`
- `./scripts/update.sh --only-images --report --jobs 4 --color=never`
- `./scripts/update.sh --report --jobs 8 --color=never`

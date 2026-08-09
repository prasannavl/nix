{pkgs}:
pkgs.runCommand "abird-host-agent-transfer-test" {
  nativeBuildInputs = [pkgs.jq];
} ''
  set -euo pipefail

  agent=${pkgs.abird-host-agent}/bin/abird-host-agent
  source_rsync="$TMPDIR/source-rsync"
  destination_rsync="$TMPDIR/destination-rsync"
  source_fallback="$TMPDIR/source-fallback"
  destination_fallback="$TMPDIR/destination-fallback"
  state="$TMPDIR/state"
  resources="$TMPDIR/resources.json"

  mkdir -p \
    "$source_rsync/nested" \
    "$destination_rsync" \
    "$source_fallback/nested" \
    "$destination_fallback" \
    "$state"
  printf 'zulip-rsync\n' > "$source_rsync/nested/data"
  ln "$source_rsync/nested/data" "$source_rsync/hardlink"
  ln -s nested/data "$source_rsync/symlink"
  chmod 0640 "$source_rsync/nested/data"
  printf 'stale\n' > "$destination_rsync/stale"

  printf 'zulip-fallback\n' > "$source_fallback/nested/data"
  ln "$source_fallback/nested/data" "$source_fallback/hardlink"
  ln -s nested/data "$source_fallback/symlink"
  chmod 0640 "$source_fallback/nested/data"
  printf 'stale\n' > "$destination_fallback/stale"

  jq -n \
    --arg sourceRsync "$source_rsync" \
    --arg destinationRsync "$destination_rsync" \
    --arg sourceFallback "$source_fallback" \
    --arg destinationFallback "$destination_fallback" \
    --arg rsync ${pkgs.rsync}/bin/rsync \
    --arg false ${pkgs.coreutils}/bin/false \
    --arg tar ${pkgs.gnutar}/bin/tar \
    '{
      schema_version: 1,
      resources: [{
        id: "service:test",
        transfers: {
          rsync: {
            source: $sourceRsync,
            destination: $destinationRsync,
            rsync_program: $rsync,
            tar_program: $tar,
            delete: true,
            fallback_copy: true
          },
          fallback: {
            source: $sourceFallback,
            destination: $destinationFallback,
            rsync_program: $false,
            tar_program: $tar,
            delete: true,
            fallback_copy: true
          }
        }
      }]
    }' > "$resources"

  ABIRD_HOST_AGENT_STATE_DIR="$state" \
  ABIRD_HOST_AGENT_RESOURCE_MANIFEST="$resources" \
    "$agent" --json job _materialize \
      --job-id rsync-copy \
      --transaction transfer-test \
      --resource service:test \
      --transfer rsync > "$TMPDIR/rsync-spec-response.json"
  jq -e .result.spec "$TMPDIR/rsync-spec-response.json" > "$TMPDIR/rsync-spec.json"
  ABIRD_HOST_AGENT_STATE_DIR="$state" \
  ABIRD_HOST_AGENT_RESOURCE_MANIFEST="$resources" \
    "$agent" --json job submit \
      --spec "$TMPDIR/rsync-spec.json" > "$TMPDIR/rsync.json"

  jq -e '
    .result.job.status == "succeeded"
    and .result.job.result.transfer.engine == "rsync"
    and .result.job.result.transfer.verification.matches
  ' "$TMPDIR/rsync.json" >/dev/null || {
    jq . "$TMPDIR/rsync.json"
    exit 1
  }
  test ! -e "$destination_rsync/stale"
  test "$(stat -c %i "$destination_rsync/nested/data")" = \
    "$(stat -c %i "$destination_rsync/hardlink")"
  test "$(stat -c %a "$destination_rsync/nested/data")" = 640

  ABIRD_HOST_AGENT_STATE_DIR="$state" \
  ABIRD_HOST_AGENT_RESOURCE_MANIFEST="$resources" \
    "$agent" --json job _materialize \
      --job-id fallback-copy \
      --transaction transfer-test \
      --resource service:test \
      --transfer fallback > "$TMPDIR/fallback-spec-response.json"
  jq -e .result.spec "$TMPDIR/fallback-spec-response.json" > "$TMPDIR/fallback-spec.json"
  ABIRD_HOST_AGENT_STATE_DIR="$state" \
  ABIRD_HOST_AGENT_RESOURCE_MANIFEST="$resources" \
    "$agent" --json job submit \
      --spec "$TMPDIR/fallback-spec.json" > "$TMPDIR/fallback.json"

  jq -e '
    .result.job.status == "succeeded"
    and .result.job.result.transfer.engine == "filesystem"
    and .result.job.result.transfer.verification.matches
    and .result.job.result.transfer.fallback_reason != null
  ' "$TMPDIR/fallback.json" >/dev/null || {
    jq . "$TMPDIR/fallback.json"
    exit 1
  }
  test ! -e "$destination_fallback/stale"
  test "$(stat -c %i "$destination_fallback/nested/data")" = \
    "$(stat -c %i "$destination_fallback/hardlink")"
  test "$(stat -c %a "$destination_fallback/nested/data")" = 640

  touch "$out"
''

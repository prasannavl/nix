#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

files=(
  "$repo_root/pkgs/p7-borders.nix"
  "$repo_root/pkgs/p7-cmds.nix"
)

for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Skipping missing file: $file" >&2
    continue
  fi

  uuid=$(sed -nE 's/^[[:space:]]*uuid = "([^"]+)";/\1/p' "$file" | head -n1)
  if [[ -z "${uuid:-}" ]]; then
    echo "Could not find uuid in $file" >&2
    exit 1
  fi

  info=$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=$uuid")
  latest_version=$(jq -er '.shell_version_map | to_entries | map(.value.version) | max' <<<"$info")

  archive_id=${uuid/@/}
  url="https://extensions.gnome.org/extension-data/${archive_id}.v${latest_version}.shell-extension.zip"
  hash=$(nix store prefetch-file --json --hash-type sha256 --unpack "$url" | jq -r .hash)

  sed -E -i \
    -e "s#(^[[:space:]]*version = \")([0-9]+)(\";)#\\1${latest_version}\\3#" \
    -e "s#(^[[:space:]]*sha256 = \").*(\";)#\\1${hash}\\2#" \
    "$file"

  echo "$(basename "$file"): version=$latest_version sha256=$hash"
done

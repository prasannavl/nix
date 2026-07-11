#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	user="${1:-}"
	home="${2:-}"
}

require_args() {
	if [ -z "$user" ] || [ -z "$home" ]; then
		printf '%s\n' "usage: podman-rootless-idmap-migrate <user> <home>" >&2
		exit 64
	fi
}

configure_rootless_storage() {
	local mount_program rootless_storage_conf tmp

	if [ ! -r /etc/containers/storage.conf ]; then
		return 0
	fi

	mount_program="$(sed -n 's/^mount_program = "\(.*\)"/\1/p' /etc/containers/storage.conf | head -n1)"
	if [ -z "$mount_program" ]; then
		return 0
	fi

	mkdir -p "$home/.config/containers"
	rootless_storage_conf="$home/.config/containers/storage.conf"
	tmp="$(mktemp "$rootless_storage_conf.XXXXXX")"
	cat >"$tmp" <<EOF
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "$mount_program"
EOF
	if [ -r "$rootless_storage_conf" ] && cmp -s "$tmp" "$rootless_storage_conf"; then
		rm -f "$tmp"
	else
		mv "$tmp" "$rootless_storage_conf"
	fi
}

has_subid_range() {
	local path="$1"

	awk -F: -v user="$user" '
		$1 == user && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 {
			found = 1
		}
		END {
			exit found ? 0 : 1
		}
	' "$path"
}

reconcile_rootless_idmap() {
	local idmap_json uidmap_count gidmap_count

	configure_rootless_storage

	if ! has_subid_range /etc/subuid || ! has_subid_range /etc/subgid; then
		printf '%s\n' "podman rootless idmap: no subordinate uid/gid range for $user; skipping migration"
		return 0
	fi

	idmap_json="$(podman info --format json)"
	uidmap_count="$(printf '%s\n' "$idmap_json" | jq -r '(.host.idMappings.uidmap // []) | length')"
	gidmap_count="$(printf '%s\n' "$idmap_json" | jq -r '(.host.idMappings.gidmap // []) | length')"

	if [ "$uidmap_count" -le 1 ] || [ "$gidmap_count" -le 1 ]; then
		printf '%s\n' "podman rootless idmap: stale single-id map for $user; running podman system migrate"
		podman system migrate
	else
		printf '%s\n' "podman rootless idmap: subordinate uid/gid map already active for $user"
	fi
}

main() {
	init_vars "$@"
	require_args
	reconcile_rootless_idmap
}

main "$@"

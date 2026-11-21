#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
	cat >&2 <<'EOF'
usage: podman-helper rootless-idmap-migrate <user> <home>
       podman-helper rootless-idmap-reconcile <user> <home> <managed-target>
EOF
}

configure_rootless_storage() {
	local home="$1" mount_program rootless_storage_conf tmp

	if [[ ! -r /etc/containers/storage.conf ]]; then
		return 0
	fi

	mount_program="$(sed -n 's/^mount_program = "\(.*\)"/\1/p' /etc/containers/storage.conf | head -n1)"
	if [[ -z $mount_program ]]; then
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
	if [[ -r $rootless_storage_conf ]] && cmp -s "$tmp" "$rootless_storage_conf"; then
		rm -f "$tmp"
	else
		mv "$tmp" "$rootless_storage_conf"
	fi
}

has_subid_range() {
	local user="$1" path="$2"

	awk -F: -v user="$user" '
		$1 == user && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 {
			found = 1
		}
		END {
			exit found ? 0 : 1
		}
	' "$path"
}

declared_idmap() {
	local user="$1" path="$2" root_id="$3"

	awk -F: -v user="$user" -v root_id="$root_id" '
		BEGIN {
			container_id = 1
			print "0:" root_id ":1"
		}
		$1 == user && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 {
			print container_id ":" $2 ":" $3
			container_id += $3
		}
	' "$path"
}

rootless_idmap_matches_declared_ranges() {
	local user="$1" idmap_json="$2" subuid_path="${3:-/etc/subuid}" subgid_path="${4:-/etc/subgid}"
	local actual_uidmap actual_gidmap expected_uidmap expected_gidmap

	if ! actual_uidmap="$(
		jq -r '.host.idMappings.uidmap // [] | .[] | [.container_id, .host_id, .size] | join(":")' <<<"$idmap_json"
	)"; then
		return 2
	fi
	if ! actual_gidmap="$(
		jq -r '.host.idMappings.gidmap // [] | .[] | [.container_id, .host_id, .size] | join(":")' <<<"$idmap_json"
	)"; then
		return 2
	fi
	if ! expected_uidmap="$(declared_idmap "$user" "$subuid_path" "$(id -u "$user")")"; then
		return 2
	fi
	if ! expected_gidmap="$(declared_idmap "$user" "$subgid_path" "$(id -g "$user")")"; then
		return 2
	fi

	[[ $actual_uidmap == "$expected_uidmap" && $actual_gidmap == "$expected_gidmap" ]]
}

rootless_idmap_needs_migration() {
	local user="$1" idmap_json match_status=0

	if ! has_subid_range "$user" /etc/subuid || ! has_subid_range "$user" /etc/subgid; then
		printf '%s\n' "podman rootless idmap: no subordinate uid/gid range for $user; skipping migration"
		return 2
	fi

	if ! idmap_json="$(podman info --format json)"; then
		return 3
	fi
	rootless_idmap_matches_declared_ranges "$user" "$idmap_json" || match_status=$?
	case "$match_status" in
	0) return 1 ;;
	1) return 0 ;;
	*) return 3 ;;
	esac
}

rootless_idmap_migrate() {
	local user="${1:-}" home="${2:-}" migration_status=0
	if (($# != 2)) || [[ -z $user || -z $home ]]; then
		usage
		return 64
	fi

	configure_rootless_storage "$home"

	rootless_idmap_needs_migration "$user" || migration_status=$?
	if ((migration_status > 2)); then
		return "$migration_status"
	fi
	if ((migration_status == 2)); then
		return 0
	fi
	if ((migration_status == 1)); then
		printf '%s\n' "podman rootless idmap: subordinate uid/gid map already active for $user"
		return 0
	fi

	printf '%s\n' "podman rootless idmap: effective map differs from declared ranges for $user; running podman system migrate"
	podman system migrate
}

rootless_idmap_reconcile() {
	local user="${1:-}" home="${2:-}" managed_target="${3:-}" target_was_active=false
	local migration_status=0 stop_status=0 migrate_status=0 restore_status=0
	if (($# != 3)) || [[ -z $user || -z $home || -z $managed_target ]]; then
		usage
		return 64
	fi

	configure_rootless_storage "$home"

	rootless_idmap_needs_migration "$user" || migration_status=$?
	if ((migration_status > 2)); then
		return "$migration_status"
	fi
	if ((migration_status == 2)); then
		return 0
	fi
	if ((migration_status == 1)); then
		printf '%s\n' "podman rootless idmap: subordinate uid/gid map already active for $user"
		return 0
	fi

	if systemctl --user is-active --quiet "$managed_target"; then
		target_was_active=true
		systemctl --user stop "$managed_target" || stop_status=$?
		if ((stop_status != 0)); then
			systemctl --user start --no-block "$managed_target" || true
			return "$stop_status"
		fi
	fi

	printf '%s\n' "podman rootless idmap: effective map differs from declared ranges for $user; running podman system migrate"
	podman system migrate || migrate_status=$?

	# Starting synchronously from ExecReload would deadlock with services ordered
	# After= this unit. Queue the target; it starts after the reload job exits.
	if [[ $target_was_active == true ]]; then
		systemctl --user start --no-block "$managed_target" || restore_status=$?
	fi

	if ((migrate_status != 0)); then
		return "$migrate_status"
	fi
	return "$restore_status"
}

main() {
	local command="${1:-}"
	[[ -n $command ]] || {
		usage
		return 64
	}
	shift

	case "$command" in
	rootless-idmap-migrate)
		rootless_idmap_migrate "$@"
		;;
	rootless-idmap-reconcile)
		rootless_idmap_reconcile "$@"
		;;
	*)
		usage
		return 64
		;;
	esac
}

main "$@"

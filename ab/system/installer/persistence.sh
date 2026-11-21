#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	label="${INSTALLER_PERSISTENCE_LABEL-}"
	mapper_name="${INSTALLER_PERSISTENCE_MAPPER_NAME-}"
	mount_point="${INSTALLER_PERSISTENCE_MOUNT_POINT-}"
	path_specs="${INSTALLER_PERSISTENCE_PATH_SPECS-}"
	password_timeout="${INSTALLER_PERSISTENCE_PASSWORD_TIMEOUT-45}"
}

require_env() {
	local name="$1"
	local value="$2"

	if [ -z "$value" ]; then
		printf 'missing required environment variable: %s\n' "$name" >&2
		exit 1
	fi
}

validate_config() {
	require_env INSTALLER_PERSISTENCE_LABEL "$label"
	require_env INSTALLER_PERSISTENCE_MAPPER_NAME "$mapper_name"
	require_env INSTALLER_PERSISTENCE_MOUNT_POINT "$mount_point"
	require_env INSTALLER_PERSISTENCE_PATH_SPECS "$path_specs"

	if [ ! -r "$path_specs" ]; then
		printf 'installer persistence path spec is not readable: %s\n' "$path_specs" >&2
		exit 1
	fi

	jq -e 'type == "array"' "$path_specs" >/dev/null
}

find_device() {
	blkid -L "$label" 2>/dev/null || true
}

unlock_device() {
	local device="$1"
	local passphrase

	if [ -e "/dev/mapper/$mapper_name" ]; then
		return
	fi

	passphrase="$(
		systemd-ask-password \
			--timeout="$password_timeout" \
			"Passphrase for installer persistence '$label':" || true
	)"
	if [ -z "$passphrase" ]; then
		printf "installer persistence passphrase not supplied; skipping\n"
		exit 0
	fi

	if ! printf '%s' "$passphrase" | cryptsetup open "$device" "$mapper_name" --type luks --key-file -; then
		printf "failed to unlock installer persistence device '%s'; skipping\n" "$label"
		exit 0
	fi
}

mount_persistence_root() {
	mkdir -p "$mount_point"
	if ! mountpoint -q "$mount_point"; then
		mount "/dev/mapper/$mapper_name" "$mount_point"
	fi
}

initialize_persistent_path() {
	local init_mode="$1"
	local init_source="$2"
	local persistent_path="$3"

	mkdir -p "$(dirname "$persistent_path")"
	if [ -e "$persistent_path" ]; then
		return
	fi

	if [ "$init_mode" = "copy" ] && [ -n "$init_source" ] && [ -d "$init_source" ]; then
		cp -aT "$init_source" "$persistent_path"
	else
		mkdir -p "$persistent_path"
	fi
}

mount_path_spec() {
	local group init_mode init_source live_path mode owner persistent_path relative_path spec writable
	spec="$1"

	live_path="$(jq -r '.path' <<<"$spec")"
	relative_path="$(jq -r '.relative' <<<"$spec")"
	init_mode="$(jq -r '.init' <<<"$spec")"
	init_source="$(jq -r '.source' <<<"$spec")"
	owner="$(jq -r '.owner' <<<"$spec")"
	group="$(jq -r '.group' <<<"$spec")"
	mode="$(jq -r '.mode' <<<"$spec")"
	writable="$(jq -r '.writable' <<<"$spec")"
	persistent_path="$mount_point/$relative_path"

	initialize_persistent_path "$init_mode" "$init_source" "$persistent_path"

	if [ "$writable" = "true" ]; then
		chmod -R u+w "$persistent_path"
	fi
	chown "$owner:$group" "$persistent_path"
	chmod "$mode" "$persistent_path"

	if mountpoint -q "$live_path"; then
		return
	fi
	if [ -L "$live_path" ] || [ -f "$live_path" ]; then
		rm -f "$live_path"
	fi
	mkdir -p "$live_path"
	mount --bind "$persistent_path" "$live_path"
}

mount_path_specs() {
	local spec

	jq -c '.[]' "$path_specs" | while IFS= read -r spec; do
		mount_path_spec "$spec"
	done
}

main() {
	local device

	init_vars
	validate_config

	device="$(find_device)"
	if [ -z "$device" ]; then
		printf "installer persistence device label '%s' not present; skipping\n" "$label"
		exit 0
	fi

	unlock_device "$device"
	mount_persistence_root
	mount_path_specs
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi

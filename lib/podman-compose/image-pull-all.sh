# shellcheck shell=bash

: "${plan:?missing podman-compose image pull plan path}"

usage() {
	cat >&2 <<'EOF'
usage:
  podman-compose-image-pull-all

Pulls all Podman Compose images declared in the generated image-pull plan.
Override the plan with NIX_PODMAN_COMPOSE_IMAGE_PULL_PLAN.
EOF
}

plan_entries() {
	jq -c '.[]?' "$plan"
}

runtime_dir_for_uid() {
	local uid
	uid="$1"
	printf '/run/user/%s\n' "$uid"
}

home_for_user() {
	local owner home
	owner="$1"
	home="$(getent passwd "$owner" | cut -d: -f6)"
	printf '%s\n' "${home:-/}"
}

ensure_runtime_dir() {
	local owner uid runtime_dir gid attempt
	owner="$1"
	uid="$2"
	runtime_dir="$3"

	if [ -d "$runtime_dir" ]; then
		return 0
	fi

	if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then
		systemctl start "user@${uid}.service" 2>/dev/null || true
		attempt=0
		while [ "$attempt" -lt 20 ]; do
			if [ -d "$runtime_dir" ]; then
				return 0
			fi
			attempt=$((attempt + 1))
			sleep 0.5
		done
	fi

	if [ "$(id -u)" = 0 ] && [ "$owner" = root ]; then
		gid="$(id -g root)"
		install -d -m 0700 -o 0 -g "$gid" "$runtime_dir"
		return 0
	fi

	printf '%s\n' "podman-compose-image-pull-all: runtime dir is absent for ${owner}: ${runtime_dir}" >&2
	return 1
}

run_as_owner() {
	local owner uid runtime_dir home current_uid
	owner="$1"
	uid="$2"
	runtime_dir="$3"
	home="$4"
	shift 4

	current_uid="$(id -u)"
	if [ "$current_uid" = "$uid" ]; then
		env \
			HOME="$home" \
			XDG_RUNTIME_DIR="$runtime_dir" \
			"$@"
		return
	fi

	if [ "$current_uid" != 0 ]; then
		printf '%s\n' "podman-compose-image-pull-all: run as root or as owning user '${owner}'" >&2
		return 1
	fi

	setpriv \
		--reuid="$owner" \
		--regid="$(id -g "$owner")" \
		--init-groups \
		env \
		HOME="$home" \
		XDG_RUNTIME_DIR="$runtime_dir" \
		"$@"
}

pull_entry() {
	local entry owner uid service_name metadata helper image_tag runtime_dir home label status_file status
	entry="$1"

	owner="$(jq -r '.user' <<<"$entry")"
	uid="$(jq -r '.uid' <<<"$entry")"
	service_name="$(jq -r '.serviceName' <<<"$entry")"
	metadata="$(jq -r '.metadataFile' <<<"$entry")"
	helper="$(jq -r '.helper' <<<"$entry")"
	image_tag="$(jq -r '.imageTag' <<<"$entry")"
	runtime_dir="$(runtime_dir_for_uid "$uid")"
	home="$(home_for_user "$owner")"
	label="declared compose images"
	if [ -n "$image_tag" ] && [ "$image_tag" != "0" ] && [ "$image_tag" != "null" ]; then
		label="tag=${image_tag}"
	fi

	ensure_runtime_dir "$owner" "$uid" "$runtime_dir"
	status_file="$(mktemp "${runtime_dir}/image-pull-status.XXXXXX")"
	chown "$uid:$(id -g "$owner")" "$status_file" 2>/dev/null || true
	chmod 0600 "$status_file"
	if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$home" \
		env \
		PATH=/run/wrappers/bin:/run/current-system/sw/bin \
		NIX_PODMAN_COMPOSE_METADATA="$metadata" \
		NIX_PODMAN_COMPOSE_SERVICE_NAME="$service_name" \
		NIX_PODMAN_COMPOSE_IMAGE_PULL_STATUS_FILE="$status_file" \
		"$helper" image-pull; then
		rm -f "$status_file"
		return 1
	fi
	status="$(cat "$status_file" 2>/dev/null || true)"
	rm -f "$status_file"

	if [ "$status" = pulled ]; then
		printf '%s\n' "podman-compose-image-pull-all: pulled ${service_name} images (${label})"
		return 0
	fi
	if [ "$status" = skipped ]; then
		return 2
	fi
	printf '%s\n' "podman-compose-image-pull-all: checked ${service_name} images (${label})"
	return 0
}

main() {
	local entry count=0 pulled_count=0 skipped_count=0

	if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
		usage
		return 0
	fi
	if [ "$#" -gt 0 ]; then
		usage
		return 1
	fi

	if [ ! -s "$plan" ]; then
		return 0
	fi

	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		count=$((count + 1))
		if pull_entry "$entry"; then
			pulled_count=$((pulled_count + 1))
		else
			case "$?" in
			2)
				skipped_count=$((skipped_count + 1))
				;;
			*)
				return 1
				;;
			esac
		fi
	done < <(plan_entries)

	if [ "$count" -eq 0 ]; then
		return 0
	fi
	if [ "$pulled_count" -gt 0 ]; then
		printf '%s\n' "podman-compose-image-pull-all: completed ${pulled_count} image pull(s)"
	elif [ "$skipped_count" -ne "$count" ]; then
		printf '%s\n' "podman-compose-image-pull-all: checked ${count} image pull target(s)"
	fi
}

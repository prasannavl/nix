# shellcheck shell=bash

: "${plan:?missing podman-compose image pull plan path}"

usage() {
	cat >&2 <<'EOF'
usage:
  podman-compose-image-pull-all

Acquire the candidate generation's remote Compose and Quadlet images.
Override the plan with NIX_PODMAN_COMPOSE_IMAGE_PULL_PLAN.
EOF
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

pull_compose_entry() {
	local entry="$1" owner="$2" uid="$3" service_name="$4" runtime_dir="$5" home="$6"
	local metadata preflight_metadata helper image_tag label status_file status
	local -a helper_env=()
	metadata="$(jq -r '.metadataFile' <<<"$entry")"
	preflight_metadata="$(jq -r '.runtimePreflightMetadata // empty' <<<"$entry")"
	helper="$(jq -r '.helper' <<<"$entry")"
	image_tag="$(jq -r '.imageTag' <<<"$entry")"
	label="declared compose images"
	if [ -n "$image_tag" ] && [ "$image_tag" != "0" ] && [ "$image_tag" != "null" ]; then
		label="tag=${image_tag}"
	fi

	if ! status_file="$(mktemp "${runtime_dir}/image-pull-status.XXXXXX")"; then
		return 1
	fi
	chown "$uid:$(id -g "$owner")" "$status_file" 2>/dev/null || true
	if ! chmod 0600 "$status_file"; then
		rm -f "$status_file"
		return 1
	fi
	helper_env=(
		"PATH=/run/wrappers/bin:/run/current-system/sw/bin"
		"NIX_PODMAN_COMPOSE_METADATA=$metadata"
		"NIX_PODMAN_COMPOSE_SERVICE_NAME=$service_name"
		"ABIRD_IMAGE_ITEM=${image_item-}"
		"NIX_PODMAN_COMPOSE_IMAGE_PULL_STATUS_FILE=$status_file"
		"NIX_PODMAN_COMPOSE_IMAGE_PULL_PREFLIGHT_POLICY=prepare"
	)
	if [ -n "$preflight_metadata" ]; then
		helper_env+=("NIX_PODMAN_COMPOSE_RUNTIME_PREFLIGHT_METADATA=$preflight_metadata")
	fi
	if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$home" \
		env "${helper_env[@]}" "$helper" image-pull; then
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
	if [ "$status" = deferred ]; then
		printf '%s\n' "podman-compose-image-pull-all: deferred ${service_name} images to activation preflight"
		return 3
	fi
	printf '%s\n' "podman-compose-image-pull-all: checked ${service_name} images (${label})"
	return 0
}

pull_entry() {
	local entry="$1" service_name="$2" backend="$3" owner uid runtime_dir home refs status=0
	local -a images
	owner="$(jq -er '.user' <<<"$entry")" || return 1
	uid="$(jq -er '.uid' <<<"$entry")" || return 1

	if ! getent passwd "$owner" >/dev/null; then
		printf '%s%s\n' \
			"podman-compose-image-pull-all: skipping pre-activation pull for ${service_name}; " \
			"owner ${owner} is absent, so service activation will pull it"
		return 3
	fi
	if [[ $(id -u "$owner") != "$uid" ]]; then
		printf 'image acquisition: uid mismatch for %s (candidate %s)\n' "$owner" "$uid" >&2
		return 1
	fi
	home="$(home_for_user "$owner")" || return 1
	runtime_dir="$(runtime_dir_for_uid "$uid")"
	ensure_runtime_dir "$owner" "$uid" "$runtime_dir" || return 1

	case "$backend" in
	compose)
		pull_compose_entry "$entry" "$owner" "$uid" "$service_name" "$runtime_dir" "$home"
		;;
	quadlet)
		refs="$(jq -er '.images[]' <<<"$entry")" || return 1
		mapfile -t images <<<"$refs"
		printf 'Preparing %s images for %s: %s\n' "$service_name" "$owner" "${images[*]}"
		(
			cd -- "$home" || exit 1
			run_as_owner "$owner" "$uid" "$runtime_dir" "$home" \
				env -i HOME="$home" USER="$owner" LOGNAME="$owner" XDG_RUNTIME_DIR="$runtime_dir" \
				ABIRD_IMAGE_ITEM="${image_item-}" PATH="${owner_engine_path:?missing owner engine path}" podman-owner-images "${images[@]}"
		) || status="$?"
		if [ "$status" -eq 75 ]; then
			printf 'image acquisition: %s is busy; deferring %s to native activation\n' "$owner" "$service_name"
			return 3
		fi
		[ "$status" -eq 0 ] || return 1
		;;

	esac
}

image_progress() {
	[[ -z ${image_item-} ]] || printf '[prefetch-podman-image] item %s %s\n' "$image_item" "$1" >&2
}

main() {
	local entries entry total image_item="" service_name label backend count=0 pulled_count=0 skipped_count=0 deferred_count=0

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

	total="$(jq -er 'length' "$plan")" || return 1
	entries="$(jq -c '.[]' "$plan")" || return 1
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		count=$((count + 1))
		service_name="$(jq -er '.serviceName' <<<"$entry")" || return 1
		backend="$(jq -er '.backend // "compose"' <<<"$entry")" || return 1
		case "$backend" in
		compose | quadlet) ;;
		*)
			printf 'unknown image acquisition backend: %s\n' "$backend" >&2
			return 1
			;;
		esac
		if [[ ${ABIRD_ACQUIRE_PROGRESS:-0} == 1 ]]; then
			label="$service_name"
			[[ $label =~ ^[a-zA-Z0-9_.@-]{1,128}$ ]] || label=service
			image_item="$count/$total $backend $label"
			image_progress checking
		fi
		if pull_entry "$entry" "$service_name" "$backend"; then
			image_progress ready
			pulled_count=$((pulled_count + 1))
		else
			case "$?" in
			2)
				image_progress ready
				skipped_count=$((skipped_count + 1))
				;;
			3)
				image_progress deferred
				deferred_count=$((deferred_count + 1))
				;;
			*)
				image_progress failed
				return 1
				;;
			esac
		fi
	done <<<"$entries"

	if [ "$count" -eq 0 ]; then
		return 0
	fi
	if [[ ${ABIRD_ACQUIRE_PROGRESS:-0} == 1 ]]; then
		printf '[prefetch-podman-image] ok=%d/%d deferred=%d failed=0\n' \
			"$((count - deferred_count))" "$count" "$deferred_count" >&2
	fi
	if [ "$pulled_count" -gt 0 ]; then
		printf '%s\n' "podman-compose-image-pull-all: prepared ${pulled_count} image set(s)"
	elif [ "$deferred_count" -gt 0 ]; then
		printf '%s\n' "podman-compose-image-pull-all: deferred ${deferred_count} image pull(s) to activation"
	elif [ "$skipped_count" -ne "$count" ]; then
		printf '%s\n' "podman-compose-image-pull-all: checked ${count} image pull target(s)"
	fi
}

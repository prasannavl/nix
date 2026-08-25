#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage:
  nginx-helper install-config --source PATH --target PATH [--preserve]
  nginx-helper reload-user-service --runtime-user USER --service-unit UNIT [--best-effort]
  nginx-helper validate-runtime-candidate \
    --runtime-user USER \
    --runtime-uid UID \
    --service-unit UNIT \
    --candidate-path PATH \
    [--compose-working-dir DIR --compose-service SERVICE] \
    CANDIDATE

Commands:
  install-config
    Install a generated Nginx config file, optionally preserving an existing
    runtime-owned file.
  reload-user-service
    Ask a user's systemd manager to reload or restart an Nginx service.
  validate-runtime-candidate
    Validate a candidate Nginx fragment with the image and volumes owned by the
    running service, but in an isolated network namespace.
USAGE
}

die() {
	echo "error: $*" >&2
	exit 1
}

need_value() {
	[ "$#" -ge 2 ] || die "missing value for $1"
}

require_nonnegative_integer() {
	local name="$1" value="$2"

	[[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be a nonnegative integer"
}

run_as_runtime_user() {
	local runtime_user="$1" runtime_dir="$2"
	shift 2

	runuser -u "${runtime_user}" -- env XDG_RUNTIME_DIR="${runtime_dir}" "$@"
}

install_config_command() {
	local source="" target="" preserve="false"

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--source)
			need_value "$@"
			source="$2"
			shift 2
			;;
		--target)
			need_value "$@"
			target="$2"
			shift 2
			;;
		--preserve)
			preserve="true"
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "unknown install-config argument: $1"
			;;
		esac
	done

	[ -n "${source}" ] || die "--source is required"
	[ -n "${target}" ] || die "--target is required"
	[ -f "${source}" ] || die "source is not a regular file: ${source}"
	[[ "${target}" == /* ]] || die "--target must be absolute"
	if [ "${preserve}" = "true" ] && [ -e "${target}" ]; then
		return 0
	fi

	install -Dm0644 "${source}" "${target}"
}

reload_user_service_command() {
	local runtime_user="" service_unit="" best_effort="false"

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--runtime-user)
			need_value "$@"
			runtime_user="$2"
			shift 2
			;;
		--service-unit)
			need_value "$@"
			service_unit="$2"
			shift 2
			;;
		--best-effort)
			best_effort="true"
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "unknown reload-user-service argument: $1"
			;;
		esac
	done

	[ -n "${runtime_user}" ] || die "--runtime-user is required"
	[ -n "${service_unit}" ] || die "--service-unit is required"
	if systemctl --no-block --user -M "${runtime_user}@" \
		try-reload-or-restart "${service_unit}"; then
		return 0
	fi
	[ "${best_effort}" = "true" ] ||
		die "failed to reload or restart ${service_unit} for ${runtime_user}"
}

discover_quadlet_containers() {
	local runtime_user="$1" runtime_dir="$2" service_unit="$3" unit=""
	local -a container_units=()

	mapfile -t container_units < <(
		run_as_runtime_user "${runtime_user}" "${runtime_dir}" \
			systemctl --user show "${service_unit}" --property=ConsistsOf --value |
			tr ' ' '\n' |
			while IFS= read -r unit; do
				case "${unit}" in
				*-container.service) printf '%s\n' "${unit}" ;;
				esac
			done
	)

	for unit in "${container_units[@]}"; do
		run_as_runtime_user "${runtime_user}" "${runtime_dir}" \
			podman ps \
			--filter "label=PODMAN_SYSTEMD_UNIT=${unit}" \
			--format '{{.ID}}'
	done
}

discover_compose_containers() {
	local runtime_user="$1" runtime_dir="$2" working_dir="$3" service="$4"

	run_as_runtime_user "${runtime_user}" "${runtime_dir}" \
		podman ps \
		--filter "label=com.docker.compose.project.working_dir=${working_dir}" \
		--filter "label=com.docker.compose.service=${service}" \
		--format '{{.ID}}'
}

validate_runtime_candidate_command() {
	local runtime_user="" runtime_uid="" service_unit="" candidate_path=""
	local compose_working_dir="" compose_service="" candidate="" container="" image=""
	local runtime_dir=""
	local -a containers=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--runtime-user)
			need_value "$@"
			runtime_user="$2"
			shift 2
			;;
		--runtime-uid)
			need_value "$@"
			runtime_uid="$2"
			shift 2
			;;
		--service-unit)
			need_value "$@"
			service_unit="$2"
			shift 2
			;;
		--candidate-path)
			need_value "$@"
			candidate_path="$2"
			shift 2
			;;
		--compose-working-dir)
			need_value "$@"
			compose_working_dir="$2"
			shift 2
			;;
		--compose-service)
			need_value "$@"
			compose_service="$2"
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		--)
			shift
			[ "$#" -eq 1 ] || die "validate-runtime-candidate requires one candidate"
			candidate="$1"
			shift
			;;
		-*)
			die "unknown validate-runtime-candidate argument: $1"
			;;
		*)
			[ -z "${candidate}" ] || die "validate-runtime-candidate requires one candidate"
			candidate="$1"
			shift
			;;
		esac
	done

	[ -n "${runtime_user}" ] || die "--runtime-user is required"
	[ -n "${runtime_uid}" ] || die "--runtime-uid is required"
	[ -n "${service_unit}" ] || die "--service-unit is required"
	[ -n "${candidate_path}" ] || die "--candidate-path is required"
	[ -n "${candidate}" ] || die "candidate is required"
	require_nonnegative_integer "--runtime-uid" "${runtime_uid}"
	[[ "${candidate_path}" == /* ]] || die "--candidate-path must be absolute"
	[ -f "${candidate}" ] || die "candidate is not a regular file: ${candidate}"
	if [ -n "${compose_working_dir}" ] || [ -n "${compose_service}" ]; then
		[ -n "${compose_working_dir}" ] && [ -n "${compose_service}" ] ||
			die "--compose-working-dir and --compose-service must be used together"
	fi

	runtime_dir="/run/user/${runtime_uid}"
	mapfile -t containers < <(
		discover_quadlet_containers \
			"${runtime_user}" "${runtime_dir}" "${service_unit}"
	)
	if [ "${#containers[@]}" -eq 0 ] && [ -n "${compose_working_dir}" ]; then
		mapfile -t containers < <(
			discover_compose_containers \
				"${runtime_user}" "${runtime_dir}" \
				"${compose_working_dir}" "${compose_service}"
		)
	fi

	if [ "${#containers[@]}" -ne 1 ]; then
		printf 'expected exactly one running container owned by %s, found %s\n' \
			"${service_unit}" "${#containers[@]}" >&2
		exit 1
	fi

	container="${containers[0]}"
	image="$(
		run_as_runtime_user "${runtime_user}" "${runtime_dir}" \
			podman inspect --format '{{.Image}}' "${container}"
	)"
	[ -n "${image}" ] || die "running container ${container} has no image identity"

	exec runuser -u "${runtime_user}" -- \
		env XDG_RUNTIME_DIR="${runtime_dir}" \
		podman run --rm --network none \
		--volumes-from "${container}" \
		--volume "${candidate}:${candidate_path}:ro" \
		--entrypoint nginx \
		"${image}" -t
}

main() {
	local command="${1-}"

	case "${command}" in
	install-config)
		shift
		install_config_command "$@"
		;;
	reload-user-service)
		shift
		reload_user_service_command "$@"
		;;
	validate-runtime-candidate)
		shift
		validate_runtime_candidate_command "$@"
		;;
	--help | -h)
		usage
		;;
	"")
		usage >&2
		exit 1
		;;
	*)
		die "unknown command: ${command}"
		;;
	esac
}

main "$@"

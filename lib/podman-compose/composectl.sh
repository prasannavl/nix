: "${registry:?missing podman-composectl registry path}"
: "${helper:?missing podman-compose helper path}"

usage() {
	cat >&2 <<'EOF'
usage:
  podman-composectl list
  podman-composectl <service> {start|stop|restart|reload|status}
  podman-composectl <service> {link|clean|verify|logs} [args...]

services are generated systemd user service names without ".service".
EOF
}

list_services() {
	jq -r 'keys[]' "$registry"
}

service_json() {
	local service
	service="$1"
	jq -cer --arg service "$service" '.[$service] // empty' "$registry"
}

require_runtime_dir() {
	local runtime_dir
	runtime_dir="$1"
	if [ ! -d "$runtime_dir" ]; then
		printf '%s\n' "podman-composectl: runtime dir is absent: $runtime_dir" >&2
		printf '%s\n' "podman-composectl: start the user manager or log in as the owning user first" >&2
		exit 1
	fi
}

require_user_bus() {
	local bus_path
	bus_path="$1"
	if [ ! -S "$bus_path" ]; then
		printf '%s\n' "podman-composectl: user bus is absent: $bus_path" >&2
		printf '%s\n' "podman-composectl: start the user manager or log in as the owning user first" >&2
		exit 1
	fi
}

run_as_owner() {
	local owner uid current_uid runtime_dir bus_path
	owner="$1"
	uid="$2"
	runtime_dir="$3"
	bus_path="$4"
	shift 4

	current_uid="$(id -u)"
	if [ "$current_uid" = "$uid" ]; then
		env \
			XDG_RUNTIME_DIR="$runtime_dir" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_path" \
			"$@"
		return
	fi

	if [ "$current_uid" != 0 ]; then
		printf '%s\n' "podman-composectl: run as root or as owning user '$owner'" >&2
		exit 1
	fi

	setpriv \
		--reuid="$owner" \
		--regid="$(id -g "$owner")" \
		--init-groups \
		env \
		XDG_RUNTIME_DIR="$runtime_dir" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_path" \
		"$@"
}

run_helper_action() {
	local owner uid runtime_dir bus_path metadata service_name helper_action
	owner="$1"
	uid="$2"
	runtime_dir="$3"
	bus_path="$4"
	metadata="$5"
	service_name="$6"
	helper_action="$7"
	shift 7

	run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
		env \
		PATH=/run/wrappers/bin:/run/current-system/sw/bin \
		NIX_PODMAN_COMPOSE_METADATA="$metadata" \
		NIX_PODMAN_COMPOSE_SERVICE_NAME="$service_name" \
		"$helper" "$helper_action" "$@"
}

main() {
	local service action entry owner uid unit service_name metadata runtime_dir bus_path

	if [ "$#" -eq 1 ] && [ "$1" = list ]; then
		list_services
		return
	fi

	if [ "$#" -lt 2 ]; then
		usage
		exit 1
	fi

	service="$1"
	action="$2"
	shift 2

	if ! entry="$(service_json "$service")"; then
		printf '%s\n' "podman-composectl: unknown service: $service" >&2
		printf '%s\n' "known services:" >&2
		list_services >&2
		exit 1
	fi

	owner="$(jq -r '.user' <<<"$entry")"
	uid="$(jq -r '.uid' <<<"$entry")"
	unit="$(jq -r '.unit' <<<"$entry")"
	service_name="$(jq -r '.serviceName' <<<"$entry")"
	metadata="$(jq -r '.metadataFile' <<<"$entry")"
	runtime_dir="/run/user/$uid"
	bus_path="$runtime_dir/bus"

	require_runtime_dir "$runtime_dir"

	case "$action" in
	start | stop | restart | reload | status)
		require_user_bus "$bus_path"
		run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
			systemctl --user "$action" "$unit" "$@"
		;;
	link | link-files)
		run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" link-files "$@"
		;;
	clean | cleanup | cleanup-files)
		run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" cleanup-files "$@"
		;;
	verify)
		run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" verify "$@"
		;;
	logs)
		run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" logs "$@"
		;;
	*)
		usage
		exit 1
		;;
	esac
}

# shellcheck shell=bash

: "${registry:?missing podman-composectl registry path}"
: "${helper:?missing podman-compose helper path}"

usage() {
	cat >&2 <<'EOF'
usage:
  podman-composectl list
  podman-composectl expected-units USER
  podman-composectl expected-runtime USER
  podman-composectl <service> {start|stop|restart|reload|status}
  podman-composectl <service> {link|clean|verify|repair|logs} [args...]

services are generated systemd user service names without ".service".
EOF
}

list_services() {
	jq -r 'keys[]' "$registry"
}

expected_units() {
	local owner="$1"

	jq -r --arg owner "$owner" '
		to_entries[]
		| .value
		| select(.user == $owner and (.autoStart // false) and ((.state // "running") == "running"))
		| .unit, .readyUnit, .managedUnit, (.privateRuntimeUnits[]?)
		| select(. != null and . != "")
	' "$registry" | sort -u
}

expected_runtime() {
	local bus_path encoded entries entry home owner probe_pid runtime_dir service_name state_json uid
	local -a probe_pids=() verify_command=()
	owner="$1"
	entries="$(
		jq -c --arg owner "$owner" '[
			to_entries[]
			| .value
			| select(.user == $owner and (.autoStart // false) and ((.state // "running") == "running"))
			| select(
				((.expectedComposeServices // []) | length) > 0
				or ((.expectedContainers // []) | length) > 0
			)
		]' "$registry"
	)"
	[ "$(jq -r 'length' <<<"$entries")" -gt 0 ] || return 0
	uid="$(jq -r '.[0].uid' <<<"$entries")"
	runtime_dir="/run/user/$uid"
	bus_path="$runtime_dir/bus"
	home="$(getent passwd "$owner" | cut -d: -f6)"
	[ -n "$home" ] || home=/
	require_runtime_dir "$runtime_dir"
	if ! state_json="$(
		run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
			env HOME="$home" podman ps -a --format json
	)"; then
		printf '%s\n' "query-failed user=$owner"
		return 1
	fi

	jq -r --slurpfile project_documents <(printf '%s\n' "$entries") '
		def compose_service:
			.Labels["io.podman.compose.service"]
			// .Labels["com.docker.compose.service"]
			// empty;
		def working_dir:
			.Labels["com.docker.compose.project.working_dir"]
			// .Labels["io.podman.compose.project.working_dir"]
			// empty;
		def health:
			((.Health // .HealthStatus // "") | tostring | ascii_downcase) as $health
			| if $health != "" and $health != "<nil>" then $health
			  elif ((.Status // "") | test("\\(unhealthy\\)$"; "i")) then "unhealthy"
			  elif ((.Status // "") | test("\\(starting\\)$"; "i")) then "starting"
			  elif ((.Status // "") | test("\\(healthy\\)$"; "i")) then "healthy"
			  else "none"
			  end;
		def labels_match($actual; $expected):
			all($expected | to_entries[]; . as $entry | $actual[$entry.key] == $entry.value);
		($project_documents[0] // []) as $projects
		| . as $containers
		| $projects[] as $project
		| (
			if ($project.backend // "compose") == "quadlet" then
				($project.expectedContainers // [])[] as $expected
				| {
					name: $expected.name,
					field: "runtime-service",
					matches: [
						$containers[]
						| select(labels_match((.Labels // {}); ($expected.labels // {})))
					]
				}
			else
				($project.expectedComposeServices // [])[] as $expected
				| {
					name: $expected,
					field: "compose-service",
					matches: [
						$containers[]
						| select(working_dir == $project.workingDir and compose_service == $expected)
					]
				}
			end
		) as $expectation
		| $expectation.matches as $matches
		| if ($matches | length) == 0 then
			"missing service=\($project.serviceName) \($expectation.field)=\($expectation.name)"
		  elif any($matches[]; (.State // "unknown") == "running") | not then
			"non-running service=\($project.serviceName) \($expectation.field)=\($expectation.name) states=\($matches | map(.State // "unknown") | unique | join(","))"
		  elif any($matches[]; (.State // "unknown") == "running" and health == "unhealthy") then
			"unhealthy service=\($project.serviceName) \($expectation.field)=\($expectation.name)"
		  elif any($matches[]; (.State // "unknown") == "running" and health == "starting") then
			"starting service=\($project.serviceName) \($expectation.field)=\($expectation.name)"
		  else empty
		  end
	' <<<"$state_json"

	while IFS= read -r encoded; do
		[ -n "$encoded" ] || continue
		entry="$(base64 -d <<<"$encoded")"
		service_name="$(jq -r '.serviceName' <<<"$entry")"
		verify_command=()
		mapfile -t verify_command < <(jq -r '.verifyCommand[]' <<<"$entry")
		(
			if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				env HOME="$home" "${verify_command[@]}" >/dev/null 2>&1; then
				printf '%s\n' "probe-failed service=$service_name"
			fi
		) &
		probe_pids+=("$!")
	done < <(jq -r '.[] | select(((.verifyCommand // []) | length) > 0) | @base64' <<<"$entries")
	for probe_pid in "${probe_pids[@]}"; do
		wait "$probe_pid" || true
	done
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
	if [ "$#" -eq 2 ] && [ "$1" = expected-units ]; then
		expected_units "$2"
		return
	fi
	if [ "$#" -eq 2 ] && [ "$1" = expected-runtime ]; then
		expected_runtime "$2"
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
	repair)
		run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" repair "$@"
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

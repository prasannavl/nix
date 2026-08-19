# shellcheck shell=bash

: "${registry:?missing podman-composectl registry path}"
: "${helper:?missing podman-compose helper path}"

usage() {
	cat >&2 <<'EOF'
usage:
  podman-composectl list
  podman-composectl restart-managed [USER]
  podman-composectl expected-units USER [--exclude-unit UNIT]...
  podman-composectl expected-runtime USER [--exclude-unit UNIT]...
  podman-composectl <service> {start|stop|restart|reload|status}
  podman-composectl <service> {link|clean|verify|repair|logs} [args...]

internal:
  podman-composectl drain-changed

services are generated systemd user service names without ".service".
EOF
}

list_services() {
	jq -r 'keys[]' "$registry"
}

user_bus_available() {
	[ -d "$1" ] && [ -S "$2" ]
}

restart_managed_stable_state() {
	local owner="$1" uid="$2" runtime_dir="$3" bus_path="$4" unit="$5" deadline="$6"
	local unit_state property value load_state active_state job waiting_logged=0
	local load_state_seen active_state_seen job_seen

	while true; do
		if ! unit_state="$(
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user show --property=LoadState --property=ActiveState --property=Job "$unit"
		)"; then
			printf 'podman-composectl: unable to inspect managed unit %s\n' "$unit" >&2
			return 1
		fi

		load_state=""
		active_state=""
		job=""
		load_state_seen=0
		active_state_seen=0
		job_seen=0
		while IFS='=' read -r property value; do
			case "$property" in
			LoadState)
				load_state="$value"
				load_state_seen=1
				;;
			ActiveState)
				active_state="$value"
				active_state_seen=1
				;;
			Job)
				job="$value"
				job_seen=1
				;;
			esac
		done <<<"$unit_state"
		if [ "$load_state_seen" -ne 1 ] || [ "$active_state_seen" -ne 1 ] || [ "$job_seen" -ne 1 ]; then
			printf 'podman-composectl: incomplete runtime state for managed unit %s\n' "$unit" >&2
			return 1
		fi
		case "$load_state" in
		loaded | masked) ;;
		*)
			printf 'podman-composectl: managed unit %s is not loaded: %s\n' \
				"$unit" "${load_state:-<empty>}" >&2
			return 1
			;;
		esac

		if [ -z "$job" ]; then
			case "$active_state" in
			active | failed | inactive)
				if [ "$load_state" = masked ] && [ "$active_state" != inactive ]; then
					printf 'podman-composectl: masked managed unit %s has unexpected runtime state: %s\n' \
						"$unit" "$active_state" >&2
					return 1
				fi
				if [ "$waiting_logged" -eq 1 ]; then
					printf '[managed-restart] user=%s unit=%s settled state=%s\n' \
						"$owner" "$unit" "$active_state" >&2
				fi
				printf '%s\n' "$active_state"
				return
				;;
			activating | deactivating | maintenance | refreshing | reloading) ;;
			*)
				printf 'podman-composectl: unexpected runtime state for managed unit %s: %s\n' \
					"$unit" "${active_state:-<empty>}" >&2
				return 1
				;;
			esac
		fi

		if [ "$waiting_logged" -eq 0 ]; then
			printf '[managed-restart] user=%s unit=%s waiting state=%s job=%s\n' \
				"$owner" "$unit" "${active_state:-<empty>}" "${job:-<none>}" >&2
			waiting_logged=1
		fi
		if [ "$SECONDS" -ge "$deadline" ]; then
			printf 'podman-composectl: timed out waiting for managed unit %s to settle\n' "$unit" >&2
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user show \
				--property=LoadState \
				--property=ActiveState \
				--property=SubState \
				--property=Job \
				--property=Result \
				"$unit" >&2 || true
			return 1
		fi
		sleep 1
	done
}

restart_managed() {
	local owner_filter="${1:-}" encoded_group group owner uid runtime_dir bus_path encoded entry unit auto_start
	local active_state unit_list has_autostart encoded_groups encoded_entries settle_timeout_seconds settle_deadline post_settle_deadline final_settle_deadline
	local -a restart_units=() try_restart_units=()

	settle_timeout_seconds="${NIX_PODMAN_COMPOSE_RESTART_SETTLE_TIMEOUT_SECONDS:-600}"
	case "$settle_timeout_seconds" in
	"" | *[!0-9]*)
		printf 'podman-composectl: invalid managed restart settle timeout: %s\n' "$settle_timeout_seconds" >&2
		return 1
		;;
	esac
	if [ "${#settle_timeout_seconds}" -gt 9 ]; then
		printf 'podman-composectl: invalid managed restart settle timeout: %s\n' "$settle_timeout_seconds" >&2
		return 1
	fi
	settle_timeout_seconds=$((10#$settle_timeout_seconds))

	if ! encoded_groups="$(
		jq -r --arg owner "$owner_filter" '
			[
				to_entries[].value
				| select((.state // "running") == "running")
				| select($owner == "" or .user == $owner)
			]
			| sort_by(.user, .unit)
			| group_by([.user, .uid])[]
			| {
				user: .[0].user,
				uid: .[0].uid,
				services: map({unit, autoStart})
			}
			| @base64
		' "$registry"
	)"; then
		printf 'podman-composectl: unable to read control registry: %s\n' "$registry" >&2
		return 1
	fi

	while IFS= read -r encoded_group; do
		[ -n "$encoded_group" ] || continue
		group="$(base64 -d <<<"$encoded_group")"
		owner="$(jq -r '.user' <<<"$group")"
		uid="$(jq -r '.uid' <<<"$group")"
		runtime_dir="/run/user/$uid"
		bus_path="$runtime_dir/bus"
		has_autostart="$(jq -r 'any(.services[]; .autoStart // false)' <<<"$group")"

		if ! user_bus_available "$runtime_dir" "$bus_path"; then
			if [ "$has_autostart" = true ]; then
				require_runtime_dir "$runtime_dir"
				require_user_bus "$bus_path"
			else
				printf '[managed-restart] user=%s skipped: user manager inactive and no auto-start services\n' "$owner" >&2
				continue
			fi
		fi

		settle_deadline=$((SECONDS + settle_timeout_seconds))
		restart_units=()
		try_restart_units=()
		if ! encoded_entries="$(jq -r '.services[] | @base64' <<<"$group")"; then
			printf 'podman-composectl: invalid managed service group for user %s\n' "$owner" >&2
			return 1
		fi
		while IFS= read -r encoded; do
			[ -n "$encoded" ] || continue
			entry="$(base64 -d <<<"$encoded")"
			unit="$(jq -r '.unit' <<<"$entry")"
			auto_start="$(jq -r '.autoStart // false' <<<"$entry")"
			if [ "$auto_start" = true ]; then
				restart_units+=("$unit")
				continue
			fi
			if ! active_state="$(
				restart_managed_stable_state \
					"$owner" "$uid" "$runtime_dir" "$bus_path" "$unit" "$settle_deadline"
			)"; then
				return 1
			fi
			case "$active_state" in
			active) try_restart_units+=("$unit") ;;
			failed) restart_units+=("$unit") ;;
			esac
		done <<<"$encoded_entries"

		[ "${#restart_units[@]}" -gt 0 ] || [ "${#try_restart_units[@]}" -gt 0 ] || {
			printf '[managed-restart] user=%s skipped: no active or auto-start services\n' "$owner" >&2
			continue
		}
		if [ "${#try_restart_units[@]}" -gt 0 ]; then
			unit_list="${try_restart_units[*]}"
			unit_list="${unit_list// /, }"
			printf '[managed-restart] user=%s action=try-restarting count=%d units="%s"\n' \
				"$owner" "${#try_restart_units[@]}" "$unit_list" >&2
			if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user try-restart "${try_restart_units[@]}"; then
				printf 'podman-composectl: managed conditional restart failed for user %s\n' "$owner" >&2
				return 1
			fi

			post_settle_deadline=$((SECONDS + settle_timeout_seconds))
			for unit in "${try_restart_units[@]}"; do
				if ! active_state="$(
					restart_managed_stable_state \
						"$owner" "$uid" "$runtime_dir" "$bus_path" "$unit" "$post_settle_deadline"
				)"; then
					return 1
				fi
				case "$active_state" in
				failed) restart_units+=("$unit") ;;
				esac
			done
		fi
		if [ "${#restart_units[@]}" -gt 0 ]; then
			unit_list="${restart_units[*]}"
			unit_list="${unit_list// /, }"
			printf '[managed-restart] user=%s action=restarting count=%d units="%s"\n' \
				"$owner" "${#restart_units[@]}" "$unit_list" >&2
			if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user restart "${restart_units[@]}"; then
				printf 'podman-composectl: managed restart failed for user %s\n' "$owner" >&2
				return 1
			fi
		fi
		if [ "${#try_restart_units[@]}" -gt 0 ]; then
			final_settle_deadline=$((SECONDS + settle_timeout_seconds))
			for unit in "${try_restart_units[@]}"; do
				if ! active_state="$(
					restart_managed_stable_state \
						"$owner" "$uid" "$runtime_dir" "$bus_path" "$unit" "$final_settle_deadline"
				)"; then
					return 1
				fi
				case "$active_state" in
				failed)
					printf 'podman-composectl: managed unit %s failed after restart convergence\n' "$unit" >&2
					return 1
					;;
				inactive)
					printf '[managed-restart] user=%s unit=%s preserved state=inactive after restart convergence\n' \
						"$owner" "$unit" >&2
					;;
				esac
			done
		fi
	done <<<"$encoded_groups"
}

quadlet_runtime_units() {
	local owner="$1" uid="$2" runtime_dir="$3" bus_path="$4" home="$5" service_name="$6" unit="$7"
	local dependencies dependency source_path
	local -a runtime_units=()

	if ! dependencies="$(
		run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
			env HOME="$home" systemctl --user list-dependencies --plain --no-legend --no-pager "$unit"
	)"; then
		printf 'podman-composectl: unable to discover Quadlet runtime units for %s\n' "$unit" >&2
		return 1
	fi

	while IFS= read -r dependency; do
		dependency="${dependency#"${dependency%%[![:space:]]*}"}"
		dependency="${dependency%"${dependency##*[![:space:]]}"}"
		case "$dependency" in
		"$service_name-stage.service")
			runtime_units+=("$dependency")
			continue
			;;
		"$service_name"-*.service) ;;
		*) continue ;;
		esac

		if ! source_path="$(
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				env HOME="$home" systemctl --user show --property=SourcePath --value "$dependency"
		)"; then
			printf 'podman-composectl: unable to inspect Quadlet runtime unit %s\n' "$dependency" >&2
			return 1
		fi
		case "$source_path" in
		"/etc/containers/systemd/users/$uid/"*.container | \
			"/etc/containers/systemd/users/$uid/"*.network | \
			"/etc/containers/systemd/users/$uid/"*.image)
			runtime_units+=("$dependency")
			;;
		esac
	done <<<"$dependencies"

	if ((${#runtime_units[@]} == 0)); then
		printf 'podman-composectl: Quadlet runtime graph is empty for %s\n' "$unit" >&2
		return 1
	fi
	printf '%s\n' "${runtime_units[@]}"
}

expected_units() {
	local owner excluded_units encoded entry service_name unit uid runtime_dir bus_path home dependency excluded base_units dependencies
	local -a units=()
	owner="$1"
	shift
	excluded_units="$(jq -cn --args '$ARGS.positional' "$@")"

	if ! base_units="$(
		jq -r --arg owner "$owner" --argjson excludedUnits "$excluded_units" '
			to_entries[]
			| .value
			| select(.user == $owner and (.autoStart // false) and ((.state // "running") == "running"))
			| . as $service
			| $service.managedUnit,
			  ($service
			    | select(.unit as $unit | ($excludedUnits | index($unit)) == null)
			    | .unit, .readyUnit, (.privateRuntimeUnits[]?))
			| select(. != null and . != "")
		' "$registry"
	)"; then
		return 1
	fi
	mapfile -t units <<<"$base_units"

	while IFS= read -r encoded; do
		[ -n "$encoded" ] || continue
		entry="$(base64 -d <<<"$encoded")"
		service_name="$(jq -r '.serviceName' <<<"$entry")"
		unit="$(jq -r '.unit' <<<"$entry")"
		excluded=false
		for dependency in "$@"; do
			[ "$dependency" != "$unit" ] || excluded=true
		done
		[ "$excluded" = false ] || continue
		uid="$(jq -r '.uid' <<<"$entry")"
		runtime_dir="/run/user/$uid"
		bus_path="$runtime_dir/bus"
		home="$(getent passwd "$owner" | cut -d: -f6)"
		[ -n "$home" ] || home=/
		if ! dependencies="$(quadlet_runtime_units "$owner" "$uid" "$runtime_dir" "$bus_path" "$home" "$service_name" "$unit")"; then
			return 1
		fi
		while IFS= read -r dependency; do
			[ -n "$dependency" ] || continue
			units+=("$dependency")
		done <<<"$dependencies"
	done < <(
		jq -r --arg owner "$owner" '
			to_entries[]
			| .value
			| select(.backend == "quadlet" and .user == $owner and (.autoStart // false) and ((.state // "running") == "running"))
			| @base64
		' "$registry"
	)

	printf '%s\n' "${units[@]}" | sed '/^$/d' | sort -u
}

expected_compose_runtime() {
	local bus_path encoded entries entry excluded_units home owner probe_pid runtime_dir service_name state_json uid
	local -a probe_pids=() verify_command=()
	owner="$1"
	shift
	excluded_units="$(jq -cn --args '$ARGS.positional' "$@")"
	entries="$(
		jq -c --arg owner "$owner" --argjson excludedUnits "$excluded_units" '[
			to_entries[]
			| .value
			| select(.user == $owner and (.autoStart // false) and ((.state // "running") == "running"))
			| select((.backend // "compose") != "quadlet")
			| select(.unit as $unit | ($excludedUnits | index($unit)) == null)
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

expected_quadlet_runtime() {
	local owner excluded_units encoded entry uid runtime_dir bus_path home service_name unit verify_unit probe_pid runtime_units runtime_unit
	local -a probe_pids=()
	owner="$1"
	shift
	excluded_units="$(jq -cn --args '$ARGS.positional' "$@")"

	while IFS= read -r encoded; do
		[ -n "$encoded" ] || continue
		entry="$(base64 -d <<<"$encoded")"
		uid="$(jq -r '.uid' <<<"$entry")"
		service_name="$(jq -r '.serviceName' <<<"$entry")"
		unit="$(jq -r '.unit' <<<"$entry")"
		verify_unit="${service_name}-verify.service"
		runtime_dir="/run/user/$uid"
		bus_path="$runtime_dir/bus"
		home="$(getent passwd "$owner" | cut -d: -f6)"
		[ -n "$home" ] || home=/
		require_runtime_dir "$runtime_dir"
		require_user_bus "$bus_path"
		(
			if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				env HOME="$home" systemctl --user is-active --quiet "$unit"; then
				printf '%s\n' "inactive-unit service=$service_name unit=$unit"
			elif ! run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				env HOME="$home" systemctl --user start "$verify_unit" >/dev/null 2>&1; then
				printf '%s\n' "probe-failed service=$service_name"
			elif ! runtime_units="$(quadlet_runtime_units "$owner" "$uid" "$runtime_dir" "$bus_path" "$home" "$service_name" "$unit")"; then
				printf '%s\n' "graph-query-failed service=$service_name"
			else
				while IFS= read -r runtime_unit; do
					[ -n "$runtime_unit" ] || continue
					if ! run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
						env HOME="$home" systemctl --user is-active --quiet "$runtime_unit"; then
						printf '%s\n' "inactive-unit service=$service_name unit=$runtime_unit"
					fi
				done <<<"$runtime_units"
			fi
		) &
		probe_pids+=("$!")
	done < <(
		jq -r --arg owner "$owner" --argjson excludedUnits "$excluded_units" '
			to_entries[]
			| .value
			| select(.backend == "quadlet" and .user == $owner and (.autoStart // false) and ((.state // "running") == "running"))
			| select(.unit as $unit | ($excludedUnits | index($unit)) == null)
			| @base64
		' "$registry"
	)
	for probe_pid in "${probe_pids[@]}"; do
		wait "$probe_pid" || true
	done
}

expected_runtime() {
	local status=0
	expected_compose_runtime "$@" || status=1
	expected_quadlet_runtime "$@" || status=1
	return "$status"
}

expected_command() {
	local action owner
	local -a excluded_units=()
	action="$1"
	owner="$2"
	shift 2

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--exclude-unit)
			[ "$#" -ge 2 ] || {
				usage
				return 1
			}
			excluded_units+=("$2")
			shift 2
			;;
		*)
			usage
			return 1
			;;
		esac
	done

	"$action" "$owner" "${excluded_units[@]}"
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

drain_log() {
	printf '[podman-drain] %s\n' "$*" >&2
}

drain_unit_active_state() {
	local owner="$1" uid="$2" unit="$3" runtime_dir bus_path
	runtime_dir="/run/user/$uid"
	bus_path="$runtime_dir/bus"
	run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
		systemctl --user show --property=ActiveState --value "$unit" 2>/dev/null || true
}

drain_entry_needs_drain() {
	local service_name="$1" old_stamp="$2" removal_policy="$3" new_registry="$4"
	local new_entry new_stamp

	new_entry="$(jq -c --arg service "$service_name" '.[$service] // null' "$new_registry")"
	if [[ $new_entry == null ]]; then
		[[ $removal_policy != keep ]]
		return
	fi
	new_stamp="$(jq -r '.drainStamp // ""' <<<"$new_entry")"
	[[ -z $old_stamp || $old_stamp != "$new_stamp" ]]
}

drain_entry() {
	local service_name="$1" owner="$2" uid="$3" unit="$4" old_stamp="$5" removal_policy="$6" new_registry="$7"
	local active_state

	drain_entry_needs_drain "$service_name" "$old_stamp" "$removal_policy" "$new_registry" || return 0
	if ! systemctl is-active --quiet "user@${uid}.service"; then
		drain_log "user=$owner unit=$unit skipped: user manager inactive"
		return 0
	fi
	if ! id -g "$owner" >/dev/null; then
		drain_log "user=$owner unit=$unit failed: account unavailable"
		return 1
	fi
	active_state="$(drain_unit_active_state "$owner" "$uid" "$unit")"
	case "$active_state" in
	active | activating | deactivating | reloading) ;;
	*) return 0 ;;
	esac

	drain_log "user=$owner unit=$unit action=draining"
	if ! run_as_owner "$owner" "$uid" "/run/user/$uid" "/run/user/$uid/bus" \
		systemctl --user stop "$unit"; then
		drain_log "user=$owner unit=$unit drain failed; later units were left untouched"
		return 1
	fi
	drain_log "user=$owner unit=$unit drained"
}

drain_changed_units() {
	local old_registry="$1" new_registry="$2"
	local row service_name owner uid unit old_stamp removal_policy

	[[ -f $old_registry ]] || return 0
	if [[ ! -f $new_registry ]]; then
		drain_log "new control registry is missing: $new_registry"
		return 1
	fi

	while IFS= read -r row; do
		[[ -n $row ]] || continue
		IFS=$'\t' read -r service_name owner uid unit old_stamp removal_policy < <(
			printf '%s' "$row" | base64 -d | jq -r '[.key, .value.user, .value.uid, .value.unit, (.value.drainStamp // ""), (.value.removalPolicy // "stop")] | @tsv'
		)
		drain_entry "$service_name" "$owner" "$uid" "$unit" "$old_stamp" "$removal_policy" "$new_registry" || return 1
	done < <(jq -r 'to_entries | sort_by(.value.user, .key)[] | @base64' "$old_registry")
}

drain_changed_main() {
	local old_registry="${NIX_PODMAN_COMPOSE_OLD_CONTROL_REGISTRY:-}"
	local new_registry="${NIX_PODMAN_COMPOSE_NEW_CONTROL_REGISTRY:-}"
	if [[ -z $old_registry || -z $new_registry ]]; then
		printf '%s\n' 'NIX_PODMAN_COMPOSE_OLD_CONTROL_REGISTRY and NIX_PODMAN_COMPOSE_NEW_CONTROL_REGISTRY are required' >&2
		return 2
	fi
	drain_changed_units "$old_registry" "$new_registry"
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
	local service action entry owner uid unit service_name metadata backend verify_unit runtime_dir bus_path

	if [ "$#" -eq 1 ] && [ "$1" = list ]; then
		list_services
		return
	fi
	if [ "$#" -ge 1 ] && [ "$1" = restart-managed ]; then
		[ "$#" -le 2 ] || {
			usage
			return 1
		}
		restart_managed "${2:-}"
		return
	fi
	if [ "$#" -eq 1 ] && [ "$1" = drain-changed ]; then
		drain_changed_main
		return
	fi
	if [ "$#" -ge 2 ] && [ "$1" = expected-units ]; then
		expected_command expected_units "${@:2}"
		return
	fi
	if [ "$#" -ge 2 ] && [ "$1" = expected-runtime ]; then
		expected_command expected_runtime "${@:2}"
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
	backend="$(jq -r '.backend // "compose"' <<<"$entry")"
	metadata="$(jq -r '.metadataFile // empty' <<<"$entry")"
	verify_unit="$(jq -r '.verifyUnit // empty' <<<"$entry")"
	if [ "$backend" = quadlet ]; then
		verify_unit="${service_name}-verify.service"
	fi
	runtime_dir="/run/user/$uid"
	bus_path="$runtime_dir/bus"

	require_runtime_dir "$runtime_dir"

	case "$action" in
	start | stop | restart | status)
		require_user_bus "$bus_path"
		run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
			systemctl --user "$action" "$unit" "$@"
		;;
	reload)
		require_user_bus "$bus_path"
		if [ "$backend" = quadlet ]; then
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user restart "$unit" "$@"
		else
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user reload "$unit" "$@"
		fi
		;;
	link | link-files)
		if [ "$backend" = quadlet ]; then
			require_user_bus "$bus_path"
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user restart "$unit" "$@"
		else
			run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" link-files "$@"
		fi
		;;
	clean | cleanup | cleanup-files)
		if [ "$backend" = quadlet ]; then
			require_user_bus "$bus_path"
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user stop "$unit" "${service_name}-stage.service" "$@"
		else
			run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" cleanup-files "$@"
		fi
		;;
	verify)
		if [ "$backend" = quadlet ]; then
			require_user_bus "$bus_path"
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user start "$verify_unit" "$@"
		else
			run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" verify "$@"
		fi
		;;
	repair)
		if [ "$backend" = quadlet ]; then
			require_user_bus "$bus_path"
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user reset-failed "$unit" "$verify_unit" "${service_name}-*.service"
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				systemctl --user restart "$unit" "$@"
		else
			run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" repair "$@"
		fi
		;;
	logs)
		if [ "$backend" = quadlet ]; then
			require_user_bus "$bus_path"
			run_as_owner "$owner" "$uid" "$runtime_dir" "$bus_path" \
				journalctl --user --unit "$unit" --unit "${service_name}-*" "$@"
		else
			run_helper_action "$owner" "$uid" "$runtime_dir" "$bus_path" "$metadata" "$service_name" logs "$@"
		fi
		;;
	*)
		usage
		exit 1
		;;
	esac
}

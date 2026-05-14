#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	incus_machines_reconcile_mode="${INCUS_MACHINES_RECONCILE_MODE-}"
	declared_instances="${INCUS_MACHINES_DECLARED_INSTANCES-[]}"
	host_suspend_state_dir="${INCUS_MACHINES_HOST_SUSPEND_STATE_DIR-/run/incus-machines-host-suspend}"
	host_suspend_default_policy="${INCUS_MACHINES_HOST_SUSPEND_DEFAULT_POLICY-stop}"
	host_suspend_include_vms="${INCUS_MACHINES_HOST_SUSPEND_INCLUDE_VMS-false}"
	host_suspend_grace_timeout="${INCUS_MACHINES_HOST_SUSPEND_GRACE_TIMEOUT-20}"
	host_suspend_force_timeout="${INCUS_MACHINES_HOST_SUSPEND_FORCE_TIMEOUT-10}"
	host_suspend_restart="${INCUS_MACHINES_HOST_SUSPEND_RESTART-true}"
	certificates="${INCUS_MACHINES_CERTIFICATES-[]}"
	certificates_file="${INCUS_MACHINES_CERTIFICATES_FILE-}"
	certificates_state_file="${INCUS_MACHINES_CERTIFICATES_STATE_FILE-/var/lib/incus-machines/certificates.json}"
	legacy_certificates_state_file="${INCUS_MACHINES_LEGACY_CERTIFICATES_STATE_FILE-/var/lib/incus-machines/preseed-certificates.json}"
	incus_remote_name="${INCUS_MACHINES_REMOTE_NAME-local}"
	incus_remote_address="${INCUS_MACHINES_REMOTE_ADDRESS-}"
	incus_remote_project="${INCUS_MACHINES_REMOTE_PROJECT-default}"
	incus_remote_client_cert_file="${INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE-}"
	incus_remote_client_key_file="${INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE-}"
	incus_remote_server_cert_file="${INCUS_MACHINES_REMOTE_SERVER_CERT_FILE-}"
	incus_remote_accept_certificate="${INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE-false}"
	incus_remote_config_dir="${INCUS_MACHINES_REMOTE_CONFIG_DIR-}"
	if [ -n "$certificates_file" ]; then
		certificates="$(cat "$certificates_file")"
	fi
	selected_json='[]'
}

is_remote_target() {
	[ "$incus_remote_name" != "local" ]
}

setup_incus_client() {
	local remote_add_status
	local -a remote_add_args=()

	if ! is_remote_target; then
		return 0
	fi

	[ -n "$incus_remote_address" ] || {
		echo "Remote Incus target $incus_remote_name is missing address" >&2
		exit 1
	}
	[ -n "$incus_remote_client_cert_file" ] || {
		echo "Remote Incus target $incus_remote_name is missing client certificate file" >&2
		exit 1
	}
	[ -n "$incus_remote_client_key_file" ] || {
		echo "Remote Incus target $incus_remote_name is missing client key file" >&2
		exit 1
	}

	if [ -z "$incus_remote_config_dir" ]; then
		incus_remote_config_dir="$(mktemp -d /run/incus-machines-client.XXXXXX)"
	else
		rm -rf -- "$incus_remote_config_dir"
		mkdir -p "$incus_remote_config_dir"
	fi

	chmod 0700 "$incus_remote_config_dir"
	mkdir -p "$incus_remote_config_dir/servercerts"
	cp "$incus_remote_client_cert_file" "$incus_remote_config_dir/client.crt"
	cp "$incus_remote_client_key_file" "$incus_remote_config_dir/client.key"
	chmod 0600 "$incus_remote_config_dir/client.key"
	export INCUS_CONF="$incus_remote_config_dir"

	if [ -n "$incus_remote_server_cert_file" ]; then
		cp "$incus_remote_server_cert_file" "$incus_remote_config_dir/servercerts/${incus_remote_name}.crt"
		cat >"$incus_remote_config_dir/config.yml" <<EOF
default-remote: ${incus_remote_name}
remotes:
  ${incus_remote_name}:
    addr: ${incus_remote_address}
    auth_type: tls
    project: ${incus_remote_project}
    protocol: incus
    public: false
aliases: {}
defaults:
  list_format: ""
  console_type: ""
  console_spice_command: ""
EOF
		return 0
	fi

	[ "$incus_remote_accept_certificate" = "true" ] || {
		echo "Remote Incus target $incus_remote_name must provide server cert or set acceptCertificate" >&2
		exit 1
	}

	remote_add_args=(
		"$incus_remote_name"
		"$incus_remote_address"
		--accept-certificate
		--auth-type=tls
		--project "$incus_remote_project"
	)
	if ! remote_add_status="$(incus remote add "${remote_add_args[@]}" 2>&1)"; then
		printf '%s\n' "$remote_add_status" >&2
		exit 1
	fi
}

server_ref() {
	if is_remote_target; then
		printf '%s:\n' "$incus_remote_name"
	fi
}

instance_ref() {
	local name
	name="$1"
	if is_remote_target; then
		printf '%s:%s\n' "$incus_remote_name" "$name"
	else
		printf '%s\n' "$name"
	fi
}

query_ref() {
	local path
	path="$1"
	if is_remote_target; then
		printf '%s:%s\n' "$incus_remote_name" "$path"
	else
		printf '%s\n' "$path"
	fi
}

target_image_ref() {
	local alias
	alias="$1"
	if is_remote_target; then
		printf '%s:%s\n' "$incus_remote_name" "$alias"
	else
		printf 'local:%s\n' "$alias"
	fi
}

target_remote_ref() {
	if is_remote_target; then
		printf '%s:\n' "$incus_remote_name"
	else
		printf 'local:\n'
	fi
}

storage_pool_ref() {
	local pool
	pool="$1"
	if is_remote_target; then
		printf '%s:%s\n' "$incus_remote_name" "$pool"
	else
		printf '%s\n' "$pool"
	fi
}

incus_server_info() {
	if is_remote_target; then
		incus info "$(server_ref)"
	else
		incus info
	fi
}

append_instance() {
	local name
	name="$1"
	selected_json="$(
		printf '%s' "$selected_json" |
			jq -c --arg name "$name" '. + [$name]'
	)"
}

parse_machine_selection_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--all)
			selected_json="$declared_instances"
			shift
			;;
		--instance | --machine)
			[ "$#" -ge 2 ] || {
				echo "Missing value for $1" >&2
				exit 1
			}
			append_instance "$2"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
		esac
	done

	if [ "$selected_json" = "[]" ]; then
		selected_json="$declared_instances"
	fi
}

instance_query_path() {
	local name encoded_name
	name="$1"
	encoded_name="$(jq -nr --arg value "$name" '$value | @uri')"
	printf '%s\n' "/1.0/instances/$encoded_name"
}

json_keys() {
	local json
	json="$1"
	printf '%s' "$json" | jq -r 'keys[]'
}

json_property_keys() {
	local json
	json="$1"
	printf '%s' "$json" | jq -r 'keys[] | select(. != "type")'
}

add_device_from_props() {
	local instance_name device_name props_json device_type assignment=""
	local -a add_args=()

	instance_name="$1"
	device_name="$2"
	props_json="$3"

	device_type="$(printf '%s' "$props_json" | jq -r '.type')"
	while IFS= read -r assignment; do
		add_args+=("$assignment")
	done < <(
		printf '%s' "$props_json" |
			jq -r 'to_entries[] | select(.key != "type") | "\(.key)=\(.value)"'
	)

	incus config device add "$(instance_ref "$instance_name")" "$device_name" "$device_type" "${add_args[@]}"
}

instance_status() {
	local name
	name="$1"

	incus query "$(query_ref "$(instance_query_path "$name")")" --raw 2>/dev/null |
		jq -r '.metadata.status // "unknown"' 2>/dev/null ||
		printf 'missing\n'
}

instance_metadata_json() {
	local name
	name="$1"

	incus query "$(query_ref "$(instance_query_path "$name")")" --raw 2>/dev/null |
		jq -c '.metadata // {}' 2>/dev/null ||
		echo '{}'
}

apply_instance_config_json() {
	local instance_name config_json key value
	instance_name="$1"
	config_json="$2"

	while IFS= read -r key; do
		value="$(printf '%s' "$config_json" | jq -r --arg key "$key" '.[$key]')"
		incus config set "$(instance_ref "$instance_name")" "$key=$value"
	done < <(printf '%s' "$config_json" | jq -r 'keys[]')
}

is_safe_gc_removal_dir() {
	local dir
	dir="$1"

	case "$dir" in
	"" | "/" | "/dev" | "/dev/"* | "/nix" | "/nix/"* | "/var" | "/var/" | "/var/lib" | "/var/lib/")
		return 1
		;;
	/*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

is_recoverable_start_error() {
	local output
	output="$1"

	printf '%s' "$output" | grep -Eq \
		'Unable to resolve container rootfs|Storage volume not found'
}

extract_broken_container_dir_from_delete_error() {
	local output
	output="$1"

	printf '%s\n' "$output" |
		sed -n 's/.*subvolume "\(\/var\/lib\/incus\/storage-pools\/[^"]*\/containers\/[^"]*\)".*/\1/p' |
		head -n 1
}

is_safe_broken_container_dir() {
	local instance_name dir
	instance_name="$1"
	dir="$2"

	case "$dir" in
	"/var/lib/incus/storage-pools/"*/"containers/${instance_name}")
		[ -d "$dir" ] && [ ! -e "$dir/rootfs" ]
		;;
	*)
		return 1
		;;
	esac
}

delete_instance_with_recovery() {
	local instance_name delete_output broken_dir
	instance_name="$1"

	if delete_output="$(incus delete "$(instance_ref "$instance_name")" --force 2>&1)"; then
		return 0
	fi
	printf '%s\n' "$delete_output" >&2

	if is_remote_target; then
		return 1
	fi

	if ! printf '%s' "$delete_output" | grep -q 'Not a Btrfs subvolume'; then
		return 1
	fi

	broken_dir="$(extract_broken_container_dir_from_delete_error "$delete_output")"
	if [ -z "$broken_dir" ] || ! is_safe_broken_container_dir "$instance_name" "$broken_dir"; then
		return 1
	fi

	echo "Removing broken Incus container dir $broken_dir"
	rm -rf -- "$broken_dir"
	incus delete "$instance_name" --force
}

certificate_fingerprint() {
	local cert_file fingerprint
	cert_file="$1"

	fingerprint="$(
		openssl x509 -in "$cert_file" -noout -fingerprint -sha256 |
			sed 's/.*=//' |
			tr '[:upper:]' '[:lower:]' |
			tr -d ':'
	)"
	[ -n "$fingerprint" ] || {
		echo "Unable to compute Incus certificate fingerprint" >&2
		return 1
	}
	printf '%s\n' "$fingerprint"
}

desired_certificates_state() {
	local cert_file cert_json fingerprint name tmpdir
	local index=0

	printf '%s' "$certificates" | jq -e 'type == "array"' >/dev/null

	tmpdir="$(mktemp -d)"
	certificates_tmpdir="$tmpdir"
	trap 'rm -rf -- "${certificates_tmpdir-}"' EXIT

	printf '['
	while IFS= read -r cert_json; do
		name="$(printf '%s' "$cert_json" | jq -r '.name // empty')"
		[ -n "$name" ] || {
			echo "Declared Incus certificate is missing name" >&2
			exit 1
		}

		cert_file="$tmpdir/cert-${index}.pem"
		printf '%s' "$cert_json" | jq -r '.certificate // empty' >"$cert_file"
		[ -s "$cert_file" ] || {
			echo "Declared Incus certificate $name is missing certificate material" >&2
			exit 1
		}

		fingerprint="$(certificate_fingerprint "$cert_file")"
		[ "$index" -eq 0 ] || printf ','
		jq -cn --arg name "$name" --arg fingerprint "$fingerprint" \
			'{name: $name, fingerprint: $fingerprint}'
		index=$((index + 1))
	done < <(printf '%s' "$certificates" | jq -c '.[]')
	printf ']\n'

	rm -rf -- "$tmpdir"
	certificates_tmpdir=""
	trap - EXIT
}

remove_trusted_certificates() {
	local live_trust match matches removal_state_json
	removal_state_json="$1"

	if is_remote_target; then
		live_trust="$(incus config trust list "$(server_ref)" --format=json)"
	else
		live_trust="$(incus config trust list --format=json)"
	fi
	matches="$(
		jq -nr \
			--argjson live "$live_trust" \
			--argjson removal "$removal_state_json" '
				[
					$live[] as $entry |
					select(
						any($removal[]; .name == $entry.name or .fingerprint == $entry.fingerprint)
					) |
					$entry.fingerprint
				] |
				unique |
				.[]?
			'
	)"

	while IFS= read -r match; do
		[ -n "$match" ] || continue
		echo "Removing existing Incus trusted certificate $match before reconcile"
		if is_remote_target; then
			incus config trust remove "${incus_remote_name}:$match"
		else
			incus config trust remove "$match"
		fi
	done <<<"$matches"
}

previous_certificates_state() {
	if [ -s "$certificates_state_file" ]; then
		jq -c '[.[] | {name, fingerprint}]' "$certificates_state_file"
	elif [ -s "$legacy_certificates_state_file" ]; then
		jq -c '[.[] | {name, fingerprint}]' "$legacy_certificates_state_file"
	else
		printf '[]\n'
	fi
}

add_declared_certificates() {
	local cert_file cert_json name projects restricted tmpdir type
	local index=0

	tmpdir="$(mktemp -d)"
	certificates_tmpdir="$tmpdir"
	trap 'rm -rf -- "${certificates_tmpdir-}"' EXIT

	while IFS= read -r cert_json; do
		name="$(printf '%s' "$cert_json" | jq -r '.name')"
		type="$(printf '%s' "$cert_json" | jq -r '.type // "client"')"
		restricted="$(printf '%s' "$cert_json" | jq -r '.restricted // false')"
		projects="$(printf '%s' "$cert_json" | jq -r '(.projects // []) | join(",")')"
		cert_file="$tmpdir/cert-${index}.pem"
		printf '%s' "$cert_json" | jq -r '.certificate' >"$cert_file"

		echo "Adding Incus trusted certificate $name"
		if [ "$restricted" = "true" ]; then
			if is_remote_target; then
				incus config trust add-certificate "$(server_ref)" "$cert_file" \
					--name "$name" \
					--type "$type" \
					--restricted \
					--projects "$projects"
			else
				incus config trust add-certificate "$cert_file" \
					--name "$name" \
					--type "$type" \
					--restricted \
					--projects "$projects"
			fi
		else
			if is_remote_target; then
				incus config trust add-certificate "$(server_ref)" "$cert_file" \
					--name "$name" \
					--type "$type"
			else
				incus config trust add-certificate "$cert_file" \
					--name "$name" \
					--type "$type"
			fi
		fi
		index=$((index + 1))
	done < <(printf '%s' "$certificates" | jq -c '.[]')

	rm -rf -- "$tmpdir"
	certificates_tmpdir=""
	trap - EXIT
}

commit_certificates_state() {
	local desired_state state_dir tmp_file

	desired_state="$1"
	state_dir="$(dirname "$certificates_state_file")"
	mkdir -p "$state_dir"
	tmp_file="$(mktemp "${certificates_state_file}.tmp.XXXXXX")"
	printf '%s\n' "$desired_state" >"$tmp_file"
	chmod 0644 "$tmp_file"
	mv -f "$tmp_file" "$certificates_state_file"
}

certificates_main() {
	local desired_state previous_state removal_state

	desired_state="$(desired_certificates_state)"
	previous_state="$(previous_certificates_state)"

	if ! incus_server_info >/dev/null 2>&1; then
		echo "Incus daemon is unavailable; certificate reconcile cannot continue" >&2
		exit 1
	fi

	removal_state="$(
		jq -cn \
			--argjson previous "$previous_state" \
			--argjson desired "$desired_state" '
				($previous + $desired) |
				unique_by([.name, .fingerprint])
			'
	)"
	remove_trusted_certificates "$removal_state"
	add_declared_certificates
	commit_certificates_state "$desired_state"
}

reconciler_main() {
	parse_machine_selection_args "$@"

	if ! incus_server_info >/dev/null 2>&1; then
		if [ "$incus_machines_reconcile_mode" = "strict" ]; then
			echo "Incus daemon is unavailable; reconcile cannot continue" >&2
			exit 1
		fi
		echo "Incus daemon is unavailable; skipping best-effort reconcile" >&2
		exit 0
	fi

	while IFS= read -r name; do
		[ -n "$name" ] || continue

		if ! printf '%s' "$declared_instances" | jq -e --arg name "$name" 'index($name) != null' >/dev/null; then
			echo "Skipping undeclared Incus instance: $name" >&2
			continue
		fi

		status="$(instance_status "$name")"

		if [ "$status" = "Running" ]; then
			continue
		fi

		echo "Reconciling Incus instance $name (status: $status)"
		if ! systemctl restart "incus-$name.service"; then
			if [ "$incus_machines_reconcile_mode" = "strict" ]; then
				exit 1
			fi
			echo "Best-effort instance reconcile failed for $name; continuing" >&2
		fi
	done < <(echo "$selected_json" | jq -r '.[]')
}

settlement_main() {
	local timeout_secs interval_secs deadline pending name expected_ip expected_ssh_port wait_for_ssh
	local instance_json status instance_state_json

	timeout_secs=180
	interval_secs=2

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--all | --instance | --machine)
			break
			;;
		--timeout)
			[ "$#" -ge 2 ] || {
				echo "Missing value for --timeout" >&2
				exit 1
			}
			timeout_secs="$2"
			shift 2
			;;
		--interval)
			[ "$#" -ge 2 ] || {
				echo "Missing value for --interval" >&2
				exit 1
			}
			interval_secs="$2"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
		esac
	done

	parse_machine_selection_args "$@"

	if ! incus_server_info >/dev/null 2>&1; then
		echo "Incus daemon is unavailable; settle cannot continue" >&2
		exit 1
	fi

	deadline="$(($(date +%s) + timeout_secs))"
	while :; do
		pending=0

		while IFS= read -r name; do
			[ -n "$name" ] || continue

			if ! printf '%s' "$declared_instances" | jq -e --arg name "$name" 'index($name) != null' >/dev/null; then
				echo "Skipping undeclared Incus instance: $name" >&2
				continue
			fi

			expected_ip="$(
				printf '%s' "${INCUS_MACHINES_INSTANCE_IPV4_ADDRESSES:-"{}"}" | jq -r --arg name "$name" '.[$name] // ""'
			)"
			expected_ssh_port="$(
				printf '%s' "${INCUS_MACHINES_INSTANCE_SSH_PORTS:-"{}"}" | jq -r --arg name "$name" '.[$name] // 22'
			)"
			wait_for_ssh="$(
				printf '%s' "${INCUS_MACHINES_INSTANCE_WAIT_FOR_SSH:-"{}"}" | jq -r --arg name "$name" '.[$name] // true'
			)"
			instance_json="$(instance_metadata_json "$name")"
			status="$(printf '%s' "$instance_json" | jq -r 'if . == {} then "missing" else .status // "unknown" end')"
			instance_state_json='{}'

			if [ "$status" != "Running" ]; then
				pending=1
				echo "Waiting for Incus instance $name to reach Running (current: $status)" >&2
				continue
			fi

			instance_state_json="$(
				incus query "$(query_ref "$(instance_query_path "$name")/state")" --raw 2>/dev/null |
					jq -c '.metadata // {}' 2>/dev/null ||
					echo '{}'
			)"

			if ! timeout 10 incus exec "$(instance_ref "$name")" -- true >/dev/null 2>&1; then
				pending=1
				echo "Waiting for Incus instance $name to accept incus exec" >&2
				continue
			fi

			if [ -n "$expected_ip" ] && ! printf '%s' "$instance_state_json" |
				jq -e --arg ip "$expected_ip" '
          .network // {}
          | to_entries[]
          | select(.key != "lo")
          | .value.addresses[]?
          | select(.family == "inet" and .address == $ip)
        ' >/dev/null 2>&1; then
				pending=1
				echo "Waiting for Incus instance $name to report expected IPv4 ${expected_ip}" >&2
				continue
			fi

			if [ "$wait_for_ssh" = "true" ] && [ -n "$expected_ip" ] && ! timeout 5 \
				bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "$expected_ip" "$expected_ssh_port" \
				>/dev/null 2>&1; then
				pending=1
				echo "Waiting for Incus instance $name SSH on ${expected_ip}:${expected_ssh_port}" >&2
				continue
			fi
		done < <(echo "$selected_json" | jq -r '.[]')

		if [ "$pending" -eq 0 ]; then
			exit 0
		fi

		if [ "$(date +%s)" -ge "$deadline" ]; then
			echo "Timed out waiting for Incus instance readiness" >&2
			exit 1
		fi

		sleep "$interval_secs"
	done
}

machine_main() {
	local state_file state_json
	local name instance_name desired_config_hash desired_boot_tag desired_recreate_tag
	local needs_create needs_recreate needs_restart current_config_hash current_recreate_tag current_boot_tag
	local current_instance current_devices current_config current_status desired_disks desired_disk_gc_metadata
	local desired_props current_props dev_exists dev_source dev_pool desired_val desired_source query_name image_tag
	local instance_image create_ref create_only_devices user_meta_json config_json desired_ipv4 desired_removal_policy
	local recovery_attempted start_output
	local -a current_disk_names desired_disk_names current_prop_keys desired_prop_keys current_gc_device_names desired_gc_device_names

	state_file="${INCUS_MACHINES_INSTANCE_STATE_FILE?missing INCUS_MACHINES_INSTANCE_STATE_FILE}"
	state_json="$(cat "$state_file")"
	name="$(printf '%s' "$state_json" | jq -r '.name')"
	instance_name="$name"
	image_tag="$(printf '%s' "$state_json" | jq -r '.imageTag')"
	instance_image="$(printf '%s' "$state_json" | jq -c '.instanceImage')"
	create_ref="$(printf '%s' "$state_json" | jq -r '.createRef')"
	desired_config_hash="$(printf '%s' "$state_json" | jq -r '.configHash')"
	desired_boot_tag="$(printf '%s' "$state_json" | jq -r '.bootTag')"
	desired_recreate_tag="$(printf '%s' "$state_json" | jq -r '.recreateTag')"
	desired_disks="$(printf '%s' "$state_json" | jq -c '.desiredDisks')"
	desired_disk_gc_metadata="$(printf '%s' "$state_json" | jq -c '.desiredDiskGcMetadata')"
	create_only_devices="$(printf '%s' "$state_json" | jq -c '.createOnlyDevices')"
	user_meta_json="$(printf '%s' "$state_json" | jq -c '.userMeta')"
	config_json="$(printf '%s' "$state_json" | jq -c '.config')"
	desired_ipv4="$(printf '%s' "$state_json" | jq -r '.ipv4Address')"
	desired_removal_policy="$(printf '%s' "$state_json" | jq -r '.removalPolicy')"
	query_name="$(jq -nr --arg value "$name" '$value | @uri')"
	recovery_attempted=0

	while :; do
		needs_create=0
		needs_recreate=0
		needs_restart=0

		if ! incus info "$(instance_ref "$instance_name")" >/dev/null 2>&1; then
			needs_create=1
		else
			current_config_hash="$(incus config get "$(instance_ref "$instance_name")" user.config-hash 2>/dev/null || true)"
			current_recreate_tag="$(incus config get "$(instance_ref "$instance_name")" user.recreate-tag 2>/dev/null || true)"
			current_boot_tag="$(incus config get "$(instance_ref "$instance_name")" user.boot-tag 2>/dev/null || true)"

			if [ "$current_recreate_tag" != "$desired_recreate_tag" ] ||
				{ [ -n "$current_config_hash" ] && [ "$current_config_hash" != "$desired_config_hash" ]; }; then
				needs_recreate=1
			elif [ -n "$current_boot_tag" ] && [ "$current_boot_tag" != "$desired_boot_tag" ]; then
				needs_restart=1
			fi
		fi

		if [ "$needs_recreate" -eq 1 ]; then
			echo "Recreating $name (config hash or recreate tag changed)..."
			incus stop "$(instance_ref "$instance_name")" --force 2>/dev/null || true
			delete_instance_with_recovery "$instance_name"
			needs_create=1
		fi

		if [ "$needs_create" -eq 1 ]; then
			if [ "$instance_image" != "null" ]; then
				ensure_declared_image_present "$instance_image" "$image_tag"
			fi
			echo "Creating $name from image $(target_image_ref "${create_ref#local:}")..."
			incus create "$(target_image_ref "${create_ref#local:}")" "$(instance_ref "$name")"

			if [ "$config_json" != "null" ]; then
				apply_instance_config_json "$instance_name" "$config_json"
			fi

			if [ "$user_meta_json" != "null" ]; then
				apply_instance_config_json "$instance_name" "$user_meta_json"
			fi

			incus config device override "$(instance_ref "$instance_name")" eth0 "ipv4.address=$desired_ipv4"

			echo "Adding create-only devices for $name..."
			mapfile -t create_only_device_names < <(json_keys "$create_only_devices")
			if [ "${#create_only_device_names[@]}" -gt 0 ]; then
				for dev in "${create_only_device_names[@]}"; do
					props="$(printf '%s' "$create_only_devices" | jq -c --arg d "$dev" '.[$d]')"
					echo "  Adding device $dev ($(printf '%s' "$props" | jq -r '.type'))"
					add_device_from_props "$instance_name" "$dev" "$props"
				done
			fi
		fi

		current_instance="$(incus query "$(query_ref "/1.0/instances/$query_name")" --raw 2>/dev/null || echo '{}')"
		current_devices="$(printf '%s' "$current_instance" | jq -c '.metadata.devices // {}' 2>/dev/null || echo '{}')"
		current_config="$(printf '%s' "$current_instance" | jq -c '.metadata.config // {}' 2>/dev/null || echo '{}')"

		echo "Syncing disk devices for $name..."
		mapfile -t current_disk_names < <(
			printf '%s' "$current_devices" |
				jq -r 'to_entries[] | select(.value.type == "disk") | .key' 2>/dev/null ||
				true
		)

		if [ "${#current_disk_names[@]}" -gt 0 ]; then
			for dev in "${current_disk_names[@]}"; do
				if ! printf '%s' "$desired_disks" | jq -e --arg d "$dev" 'has($d)' >/dev/null 2>&1; then
					echo "  Removing disk device $dev"
					incus config device remove "$(instance_ref "$instance_name")" "$dev" 2>/dev/null || true
				fi
			done
		fi

		mapfile -t desired_disk_names < <(json_keys "$desired_disks")
		if [ "${#desired_disk_names[@]}" -gt 0 ]; then
			for dev in "${desired_disk_names[@]}"; do
				desired_props="$(printf '%s' "$desired_disks" | jq -c --arg d "$dev" '.[$d]')"
				current_props="$(printf '%s' "$current_devices" | jq -c --arg d "$dev" '.[$d] // null')"
				dev_exists=0
				if [ "$current_props" != "null" ]; then
					dev_exists=1
				fi

				dev_source="$(printf '%s' "$desired_props" | jq -r '.source // ""')"
				dev_pool="$(printf '%s' "$desired_props" | jq -r '.pool // ""')"
				if [ -n "$dev_source" ] && [ -n "$dev_pool" ]; then
					if ! incus storage volume show "$(storage_pool_ref "$dev_pool")" "$dev_source" >/dev/null 2>&1; then
						echo "  Creating storage volume $dev_pool/$dev_source"
						incus storage volume create "$(storage_pool_ref "$dev_pool")" "$dev_source"
					fi
				fi

				if [ "$dev_exists" -eq 0 ]; then
					echo "  Adding disk device $dev"
					add_device_from_props "$instance_name" "$dev" "$desired_props"
				else
					mapfile -t current_prop_keys < <(json_property_keys "$current_props")
					if [ "${#current_prop_keys[@]}" -gt 0 ]; then
						for key in "${current_prop_keys[@]}"; do
							if ! printf '%s' "$desired_props" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
								incus config device unset "$(instance_ref "$instance_name")" "$dev" "$key"
							fi
						done
					fi

					mapfile -t desired_prop_keys < <(json_property_keys "$desired_props")
					if [ "${#desired_prop_keys[@]}" -gt 0 ]; then
						for key in "${desired_prop_keys[@]}"; do
							desired_val="$(printf '%s' "$desired_props" | jq -r --arg k "$key" '.[$k]')"
							incus config device set "$(instance_ref "$instance_name")" "$dev" "$key" "$desired_val"
						done
					fi
				fi
			done
		fi

		incus config device set "$(instance_ref "$instance_name")" eth0 "ipv4.address=$desired_ipv4" 2>/dev/null ||
			incus config device override "$(instance_ref "$instance_name")" eth0 "ipv4.address=$desired_ipv4" 2>/dev/null || true

		incus config set "$(instance_ref "$instance_name")" "user.config-hash=$desired_config_hash"
		incus config set "$(instance_ref "$instance_name")" "user.boot-tag=$desired_boot_tag"
		incus config set "$(instance_ref "$instance_name")" "user.recreate-tag=$desired_recreate_tag"
		incus config set "$(instance_ref "$instance_name")" "user.removal-policy=$desired_removal_policy"

		mapfile -t current_gc_device_names < <(
			printf '%s' "$current_config" |
				jq -r '
        to_entries[]
        | select(.key | test("^user\\.device\\..+\\.(removal-policy|source)$"))
        | (.key | capture("^user\\.device\\.(?<name>.*)\\.(removal-policy|source)$").name)
      ' 2>/dev/null |
				sort -u ||
				true
		)

		mapfile -t desired_gc_device_names < <(json_keys "$desired_disks")
		if [ "${#desired_gc_device_names[@]}" -gt 0 ]; then
			for dev in "${desired_gc_device_names[@]}"; do
				incus config set "$(instance_ref "$instance_name")" "user.device.$dev.removal-policy=$(printf '%s' "$desired_disk_gc_metadata" | jq -r --arg d "$dev" '.[$d].removalPolicy // "keep"')"

				desired_source="$(printf '%s' "$desired_disk_gc_metadata" | jq -r --arg d "$dev" '.[$d].source // ""')"
				if [ -n "$desired_source" ]; then
					incus config set "$(instance_ref "$instance_name")" "user.device.$dev.source=$desired_source"
				else
					incus config unset "$(instance_ref "$instance_name")" "user.device.$dev.source" 2>/dev/null || true
				fi
			done
		fi

		if [ "${#current_gc_device_names[@]}" -gt 0 ]; then
			for dev in "${current_gc_device_names[@]}"; do
				if ! printf '%s' "$desired_disks" | jq -e --arg d "$dev" 'has($d)' >/dev/null 2>&1; then
					incus config unset "$(instance_ref "$instance_name")" "user.device.$dev.removal-policy" 2>/dev/null || true
					incus config unset "$(instance_ref "$instance_name")" "user.device.$dev.source" 2>/dev/null || true
				fi
			done
		fi

		if [ "$needs_restart" -eq 1 ]; then
			echo "Restarting $name (boot tag changed)..."
			incus stop "$(instance_ref "$instance_name")" --force 2>/dev/null || true
		fi

		current_status="$(incus query "$(query_ref "/1.0/instances/$query_name")" --raw 2>/dev/null | jq -r '.metadata.status // "unknown"' 2>/dev/null || printf 'missing\n')"
		if [ "$current_status" != "Running" ]; then
			if ! start_output="$(incus start "$(instance_ref "$instance_name")" 2>&1)"; then
				printf '%s\n' "$start_output" >&2
				if [ "$recovery_attempted" -eq 0 ] && is_recoverable_start_error "$start_output"; then
					echo "Recreating broken $name after failed start..."
					recovery_attempted=1
					incus stop "$(instance_ref "$instance_name")" --force 2>/dev/null || true
					delete_instance_with_recovery "$instance_name"
					continue
				fi
				exit 1
			fi
		fi

		break
	done
}

stop_instance_main() {
	local name
	name="${1?missing instance name}"
	incus stop "$(instance_ref "$name")" 2>/dev/null || true
}

ensure_declared_image_present() {
	local image desired_rebuild_tag alias image_kind image_identity current_source current_rebuild_tag
	local metadata_file rootfs_file remote_ref existing_fingerprint

	image="$1"
	desired_rebuild_tag="$2"
	alias="$(printf '%s' "$image" | jq -r '.alias')"
	image_kind="$(printf '%s' "$image" | jq -r '.kind')"
	image_identity="$(printf '%s' "$image" | jq -r '.imageIdentity')"

	current_source="$(incus image get-property "$(target_image_ref "$alias")" user.base-image-id 2>/dev/null || true)"
	current_rebuild_tag="$(incus image get-property "$(target_image_ref "$alias")" user.base-image-rebuild-tag 2>/dev/null || true)"

	if [ "$current_source" = "$image_identity" ] &&
		[ "$current_rebuild_tag" = "$desired_rebuild_tag" ] &&
		incus image info "$(target_image_ref "$alias")" >/dev/null 2>&1; then
		return 0
	fi

	if incus image info "$(target_image_ref "$alias")" >/dev/null 2>&1; then
		incus image delete "$(target_image_ref "$alias")"
	fi

	case "$image_kind" in
	local)
		metadata_file="$(printf '%s' "$image" | jq -r '.metadataFile')"
		rootfs_file="$(printf '%s' "$image" | jq -r '.rootfsFile')"

		if [ ! -f "$metadata_file" ] || [ ! -f "$rootfs_file" ]; then
			echo "Missing base image tarballs for $alias:" >&2
			echo "  $metadata_file" >&2
			echo "  $rootfs_file" >&2
			exit 1
		fi

		existing_fingerprint="$(
			incus image list "$(target_remote_ref)" --format=json 2>/dev/null |
				jq -r --arg image_identity "$image_identity" '
            map(select((.properties["user.base-image-id"] // "") == $image_identity))
            | first
            | .fingerprint // ""
          ' 2>/dev/null ||
				true
		)"

		if [ -n "$existing_fingerprint" ]; then
			incus image alias create "$(target_image_ref "$alias")" "$existing_fingerprint"
		else
			incus image import "$metadata_file" "$rootfs_file" "$(target_remote_ref)" --alias "$alias"
		fi
		;;
	remote)
		remote_ref="$(printf '%s' "$image" | jq -r '.remoteRef')"
		incus image copy "$remote_ref" "$(target_remote_ref)" --alias "$alias"
		;;
	*)
		echo "Unknown image kind for $alias: $image_kind" >&2
		exit 1
		;;
	esac

	incus image set-property "$(target_image_ref "$alias")" user.base-image-id "$image_identity"
	incus image set-property "$(target_image_ref "$alias")" user.base-image-rebuild-tag "$desired_rebuild_tag"
}

images_main() {
	local desired_rebuild_tag image

	desired_rebuild_tag="${INCUS_MACHINES_IMAGE_TAG?missing INCUS_MACHINES_IMAGE_TAG}"
	while IFS= read -r image; do
		ensure_declared_image_present "$image" "$desired_rebuild_tag"
	done < <(echo "${INCUS_MACHINES_DECLARED_IMAGES?missing INCUS_MACHINES_DECLARED_IMAGES}" | jq -c '.[]')
}

gc_main() {
	local all_containers cname managed removal_policy
	local -a dirs_to_remove

	if is_remote_target; then
		all_containers="$(incus list "$(server_ref)" --format json 2>/dev/null)" || {
			echo "Failed to list Incus containers for garbage collection" >&2
			exit 1
		}
	elif ! all_containers="$(incus list --format json 2>/dev/null)"; then
		echo "Failed to list Incus containers for garbage collection" >&2
		exit 1
	fi

	while IFS= read -r row; do
		cname="$(echo "$row" | jq -r '.name')"
		managed="$(echo "$row" | jq -r '.config["user.managed-by"] // ""')"

		[ "$managed" = "nixos" ] || continue

		if echo "$declared_instances" | jq -e --arg n "$cname" 'index($n) != null' >/dev/null 2>&1; then
			continue
		fi

		removal_policy="$(echo "$row" | jq -r '.config["user.removal-policy"] // "delete-container"')"
		echo "GC: container $cname (policy: $removal_policy)"

		case "$removal_policy" in
		stop-only)
			incus stop "$(instance_ref "$cname")" --force 2>/dev/null || true
			;;
		delete-container)
			incus delete "$(instance_ref "$cname")" --force 2>/dev/null || true
			;;
		delete-all)
			mapfile -t dirs_to_remove < <(
				echo "$row" | jq -r '
            .config as $cfg
            | $cfg
            | to_entries[]
            | select(.key | test("^user\\.device\\..+\\.removal-policy$"))
            | select(.value == "delete")
            | (.key | capture("^user\\.device\\.(?<name>.*)\\.removal-policy$").name) as $name
            | $cfg["user.device.\($name).source"] // empty
          '
			)

			incus delete "$(instance_ref "$cname")" --force 2>/dev/null || true

			if [ "${#dirs_to_remove[@]}" -gt 0 ]; then
				for dir in "${dirs_to_remove[@]}"; do
					[ -d "$dir" ] || continue
					if ! is_safe_gc_removal_dir "$dir"; then
						echo "Refusing to remove unsafe source dir: $dir" >&2
						exit 1
					fi
					echo "  Removing source dir: $dir"
					rm -rf "$dir"
				done
			fi
			;;
		esac
	done < <(echo "$all_containers" | jq -c '.[]')
}

host_suspend_state_file() {
	printf '%s\n' "${host_suspend_state_dir%/}/stopped-instances.json"
}

host_suspend_list_candidates() {
	incus list --all-projects --format json |
		jq -c \
			--arg default_policy "$host_suspend_default_policy" \
			--arg include_vms "$host_suspend_include_vms" '
        [
          .[]
          | select(.status == "Running")
          | select(.type == "container" or ($include_vms == "true" and .type == "virtual-machine"))
          | select((.config["user.host-suspend.policy"] // $default_policy) != "ignore")
          | {
              name,
              project: (.project // "default"),
              type,
              policy: (.config["user.host-suspend.policy"] // $default_policy)
            }
        ]
      '
}

host_suspend_pre_main() {
	local state_file tmp_file candidates row name project failed

	if ! incus info >/dev/null 2>&1; then
		echo "Incus daemon is unavailable; skipping host-suspend pre hook" >&2
		return 0
	fi

	mkdir -p "$host_suspend_state_dir"
	state_file="$(host_suspend_state_file)"
	tmp_file="$state_file.tmp"
	candidates="$(host_suspend_list_candidates)"
	printf '%s\n' "$candidates" >"$tmp_file"
	mv "$tmp_file" "$state_file"

	if [ "$(printf '%s' "$candidates" | jq 'length')" -eq 0 ]; then
		echo "No running Incus instances need host-suspend handling"
		return 0
	fi

	failed=0
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		name="$(printf '%s' "$row" | jq -r '.name')"
		project="$(printf '%s' "$row" | jq -r '.project')"

		echo "Stopping Incus instance $project/$name before host sleep"
		if incus stop --project "$project" "$name" --timeout "$host_suspend_grace_timeout"; then
			continue
		fi

		echo "Graceful stop timed out for $project/$name; forcing stop" >&2
		if ! timeout "$host_suspend_force_timeout" incus stop --project "$project" "$name" --force; then
			echo "Failed to force-stop Incus instance $project/$name" >&2
			failed=1
		fi
	done < <(printf '%s' "$candidates" | jq -c '.[]')

	return "$failed"
}

host_suspend_post_main() {
	local state_file candidates row name project status failed

	state_file="$(host_suspend_state_file)"
	[ -f "$state_file" ] || return 0
	candidates="$(cat "$state_file")"
	rm -f "$state_file"

	if [ "$host_suspend_restart" != "true" ]; then
		return 0
	fi

	if ! incus info >/dev/null 2>&1; then
		echo "Incus daemon is unavailable; skipping host-suspend post hook" >&2
		return 0
	fi

	failed=0
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		name="$(printf '%s' "$row" | jq -r '.name')"
		project="$(printf '%s' "$row" | jq -r '.project')"
		status="$(
			incus list --project "$project" "$name" --format json 2>/dev/null |
				jq -r '.[0].status // "missing"' 2>/dev/null ||
				printf 'missing\n'
		)"

		if [ "$status" = "Running" ]; then
			continue
		fi

		echo "Restarting Incus instance $project/$name after host resume"
		if ! incus start --project "$project" "$name"; then
			failed=1
		fi
	done < <(printf '%s' "$candidates" | jq -c '.[]')

	return "$failed"
}

host_suspend_main() {
	local phase
	phase="${1-}"
	case "$phase" in
	pre)
		host_suspend_pre_main
		;;
	post)
		host_suspend_post_main
		;;
	*)
		echo "usage: incus-machines-helper host-suspend <pre|post>" >&2
		exit 1
		;;
	esac
}

main() {
	local command
	init_vars
	setup_incus_client
	command="${1-}"
	[ -n "$command" ] || {
		echo "usage: incus-machines-helper <reconciler|settlement|machine|images|gc|host-suspend> [args...]" >&2
		exit 1
	}
	shift

	case "$command" in
	certificates)
		certificates_main "$@"
		;;
	reconciler)
		reconciler_main "$@"
		;;
	settlement)
		settlement_main "$@"
		;;
	machine)
		machine_main "$@"
		;;
	stop-instance)
		stop_instance_main "$@"
		;;
	images)
		images_main "$@"
		;;
	gc)
		gc_main "$@"
		;;
	host-suspend)
		host_suspend_main "$@"
		;;
	*)
		echo "unknown incus-machines-helper command: $command" >&2
		exit 1
		;;
	esac
}

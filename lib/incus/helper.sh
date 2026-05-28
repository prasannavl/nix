#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	incus_machines_reconcile_mode="${INCUS_MACHINES_RECONCILE_MODE-}"
	declared_instances="${INCUS_MACHINES_DECLARED_INSTANCES-[]}"
	drained_instances="${INCUS_MACHINES_DRAINED_INSTANCES-[]}"
	declared_instance_refs="${INCUS_MACHINES_DECLARED_INSTANCE_REFS-{}}"
	instance_names="${INCUS_MACHINES_INSTANCE_NAMES-{}}"
	instance_projects="${INCUS_MACHINES_INSTANCE_PROJECTS-{}}"
	host_suspend_state_dir="${INCUS_MACHINES_HOST_SUSPEND_STATE_DIR-/run/incus-machines-host-suspend}"
	host_suspend_default_policy="${INCUS_MACHINES_HOST_SUSPEND_DEFAULT_POLICY-stop}"
	host_suspend_include_vms="${INCUS_MACHINES_HOST_SUSPEND_INCLUDE_VMS-false}"
	host_suspend_grace_timeout="${INCUS_MACHINES_HOST_SUSPEND_GRACE_TIMEOUT-20}"
	host_suspend_force_timeout="${INCUS_MACHINES_HOST_SUSPEND_FORCE_TIMEOUT-10}"
	host_suspend_restart="${INCUS_MACHINES_HOST_SUSPEND_RESTART-true}"
	image_lock_root="${INCUS_MACHINES_IMAGE_LOCK_ROOT-/run/incus-machines/image-locks}"
	managed_gc_dir_root="${INCUS_MACHINES_MANAGED_GC_DIR_ROOT-/var/lib/incus-machines/managed-dirs}"
	controller_id="${INCUS_MACHINES_CONTROLLER_ID-}"
	gc_projects="${INCUS_MACHINES_GC_PROJECTS-[]}"
	certificates="${INCUS_MACHINES_CERTIFICATES-[]}"
	certificates_file="${INCUS_MACHINES_CERTIFICATES_FILE-}"
	certificates_state_file="${INCUS_MACHINES_CERTIFICATES_STATE_FILE-/var/lib/incus-machines/certificates.json}"
	certificate_delegation_name="${INCUS_MACHINES_CERTIFICATE_DELEGATION_NAME-}"
	certificate_delegation_project="${INCUS_MACHINES_CERTIFICATE_DELEGATION_PROJECT-}"
	certificate_delegation_source_file="${INCUS_MACHINES_CERTIFICATE_DELEGATION_SOURCE_FILE-}"
	certificate_delegation_state_file="${INCUS_MACHINES_CERTIFICATE_DELEGATION_STATE_FILE-}"
	certificate_delegation_name_prefix="${INCUS_MACHINES_CERTIFICATE_DELEGATION_NAME_PREFIX-}"
	certificate_delegation_max_certificates="${INCUS_MACHINES_CERTIFICATE_DELEGATION_MAX_CERTIFICATES-32}"
	certificate_delegations_root="${INCUS_MACHINES_CERTIFICATE_DELEGATIONS_ROOT-/var/lib/incus-delegations}"
	certificate_delegations="{}"
	certificate_delegations_file="${INCUS_MACHINES_CERTIFICATE_DELEGATIONS_FILE-}"
	certificate_delegations_state_file="${INCUS_MACHINES_CERTIFICATE_DELEGATIONS_STATE_FILE-/var/lib/incus-machines/delegated-certificates/delegations.json}"
	remote_project_delegations_file="${INCUS_MACHINES_REMOTE_PROJECT_DELEGATIONS_FILE-}"
	preseed_migrations="[]"
	preseed_migrations_file="${INCUS_MACHINES_PRESEED_MIGRATIONS_FILE-}"
	incus_remote_name="${INCUS_MACHINES_REMOTE_NAME-local}"
	incus_remote_address="${INCUS_MACHINES_REMOTE_ADDRESS-}"
	incus_remote_project="${INCUS_MACHINES_REMOTE_PROJECT-default}"
	current_project="$incus_remote_project"
	incus_remote_client_cert_file="${INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE-}"
	incus_remote_client_key_file="${INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE-}"
	incus_remote_server_cert_file="${INCUS_MACHINES_REMOTE_SERVER_CERT_FILE-}"
	incus_remote_accept_certificate="${INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE-false}"
	incus_remote_config_dir=""
	if [ -n "$certificates_file" ]; then
		certificates="$(cat "$certificates_file")"
	fi
	if [ -n "$certificate_delegations_file" ]; then
		certificate_delegations="$(cat "$certificate_delegations_file")"
	fi
	if [ -n "$preseed_migrations_file" ]; then
		preseed_migrations="$(cat "$preseed_migrations_file")"
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

	incus_remote_config_dir="$(mktemp -d /run/incus-machines-client.XXXXXX)"
	trap 'rm -rf -- "$incus_remote_config_dir"' EXIT

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

	incus remote switch "$incus_remote_name"
}

server_ref() {
	if is_remote_target; then
		printf '%s:\n' "$incus_remote_name"
	fi
}

incus_project() {
	incus --project "$current_project" "$@"
}

incus_project_timeout() {
	local timeout_secs
	timeout_secs="$1"
	shift

	timeout "$timeout_secs" incus --project "$current_project" "$@"
}

set_current_project_for_instance() {
	local id project
	id="$1"
	project="$(
		jq -nr --argjson projects "$instance_projects" --arg id "$id" '$projects[$id] // empty' 2>/dev/null ||
			true
	)"

	if [ -n "$project" ]; then
		current_project="$project"
	elif is_remote_target; then
		current_project="$incus_remote_project"
	else
		current_project="default"
	fi
}

instance_name_for_id() {
	local id
	id="$1"
	jq -nr --argjson names "$instance_names" --arg id "$id" '$names[$id] // $id' 2>/dev/null ||
		printf '%s\n' "$id"
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
		if [[ "$path" == *\?* ]]; then
			printf '%s:%s&project=%s\n' "$incus_remote_name" "$path" "$current_project"
			return
		fi

		printf '%s:%s?project=%s\n' "$incus_remote_name" "$path" "$current_project"
		return
	fi

	if [[ "$path" == *\?* ]]; then
		printf '%s&project=%s\n' "$path" "$current_project"
		return
	fi

	printf '%s?project=%s\n' "$path" "$current_project"
}

query_response_is_error() {
	local response
	response="$1"
	printf '%s' "$response" | jq -e '(.type // "") == "error" or (.error_code // null) != null' >/dev/null 2>&1
}

record_moved_volume_attachments() {
	local attachment_device attachment_instance attachment_json attachment_status device_config_json encoded_instance instance_config_json instances_json name project target_pool target_project volume_pool volume_source
	project="$1"
	target_project="$2"
	volume_pool="$3"
	target_pool="$4"
	volume_source="$5"

	current_project="$project"
	instances_json="$(incus query "$(query_ref "/1.0/instances?recursion=2")" --raw 2>/dev/null || printf '[]')"
	while IFS= read -r attachment_json; do
		[ -n "$attachment_json" ] || continue
		attachment_instance="$(printf '%s' "$attachment_json" | jq -r '.instance')"
		attachment_device="$(printf '%s' "$attachment_json" | jq -r '.device')"
		device_config_json="$(printf '%s' "$attachment_json" | jq -c '.deviceConfig')"
		encoded_instance="$(jq -nr --arg value "$attachment_instance" '$value | @uri')"

		current_project="$project"
		if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
			continue
		fi
		attachment_status="$(printf '%s' "$instance_config_json" | jq -r '.metadata.status // .status // ""')"
		if [ "$attachment_status" = "Running" ]; then
			incus --project "$project" stop "$attachment_instance" --force
		fi

		incus config device remove --project "$project" "$attachment_instance" "$attachment_device"
		jq -cn \
			--arg project "$project" \
			--arg targetProject "$target_project" \
			--arg instance "$attachment_instance" \
			--arg device "$attachment_device" \
			--arg targetPool "$target_pool" \
			--argjson deviceConfig "$device_config_json" \
			'{
				project: $project,
				targetProject: $targetProject,
				instance: $instance,
				device: $device,
				targetPool: $targetPool,
				deviceConfig: $deviceConfig
			}' >>"$migration_volume_attachments_file"
	done < <(
		printf '%s' "$instances_json" |
			jq -c --arg pool "$volume_pool" --arg source "$volume_source" '
				(.metadata // .)[] |
				.name as $instance |
				(.devices // {}) |
				to_entries[] |
				select(
					.value.type == "disk"
					and (.value.pool // "") == $pool
					and (.value.source // "") == $source
				) |
				{
					instance: $instance,
					device: .key,
					deviceConfig: .value
				}
			'
	)
}

reattach_moved_volume_devices() {
	local attachment_json device device_config_json device_type encoded_instance instance_config_json instance_name key project target_project value
	local -a device_args=()
	project="$1"
	target_project="$2"
	instance_name="$3"

	[ -s "$migration_volume_attachments_file" ] || return 0

	while IFS= read -r attachment_json; do
		[ -n "$attachment_json" ] || continue
		device="$(printf '%s' "$attachment_json" | jq -r '.device')"
		device_config_json="$(
			printf '%s' "$attachment_json" |
				jq -c '.deviceConfig + {pool: .targetPool}'
		)"
		device_type="$(printf '%s' "$device_config_json" | jq -r '.type')"
		encoded_instance="$(jq -nr --arg value "$instance_name" '$value | @uri')"

		current_project="$target_project"
		if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
			continue
		fi

		device_args=()
		while IFS= read -r key; do
			[ -n "$key" ] || continue
			value="$(printf '%s' "$device_config_json" | jq -r --arg k "$key" '.[$k]')"
			device_args+=("$key=$value")
		done < <(printf '%s' "$device_config_json" | jq -r 'keys[] | select(. != "type")')

		if printf '%s' "$instance_config_json" | jq -e --arg device "$device" '(.metadata.devices // .devices // {}) | has($device)' >/dev/null 2>&1; then
			incus config device set --project "$target_project" "$instance_name" "$device" "${device_args[@]}"
		else
			incus config device add --project "$target_project" "$instance_name" "$device" "$device_type" "${device_args[@]}"
		fi
	done < <(
		jq -c \
			--arg project "$project" \
			--arg targetProject "$target_project" \
			--arg instance "$instance_name" \
			'select(.project == $project and .targetProject == $targetProject and .instance == $instance)' \
			"$migration_volume_attachments_file"
	)
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

instance_id_for_selector() {
	local selector
	selector="$1"
	jq -nr \
		--argjson ids "$declared_instances" \
		--argjson names "$instance_names" \
		--arg selector "$selector" '
			if ($ids | index($selector)) != null then
				$selector
			else
				($names | to_entries | map(select(.value == $selector).key)) as $matches |
				if ($matches | length) == 1 then $matches[0] else $selector end
			end
		' 2>/dev/null ||
		printf '%s\n' "$selector"
}

append_instance() {
	local id selector
	selector="$1"
	id="$(instance_id_for_selector "$selector")"
	selected_json="$(
		printf '%s' "$selected_json" |
			jq -c --arg id "$id" '. + [$id]'
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

preseed_migrations_main() {
	local current_project delete_instance_json delete_network_json device device_json device_type driver encoded_instance encoded_profile from_network from_pool from_project instance instance_config_json instance_device_json instance_json key keys_json migration migration_volume_attachments_file name network_config_json network_json network_project pool pool_config_json pool_exists pool_json prefixes_json profile profile_config_json profile_device_json profile_json project project_config_json project_config_migration_json project_exists project_instances project_json rename_network_json rename_project_json root_pool source_exists start_instance_json status stop_instance_json target_exists target_instance_config_json target_project to_network to_pool to_project unset_keys_json value volume_json
	local -a create_network_args=() create_pool_args=() create_project_args=() set_device_args=() set_network_args=() set_profile_args=() set_project_args=() move_instance_args=() move_volume_args=()

	printf '%s' "$preseed_migrations" |
		jq -e '
			type == "array"
			and all(.[]; (
				(.projects | type == "array")
				and all(.projects[]; type == "string")
				and (.unsetInstanceConfigKeyPrefixes | type == "array")
				and all(.unsetInstanceConfigKeyPrefixes[]; type == "string")
				and (.ensureStoragePools | type == "array")
				and all(.ensureStoragePools[]; (
					(.name | type == "string")
					and (.driver | type == "string")
					and (.config | type == "object")
					and all(.config[]; type == "string")
				))
				and (.ensureNetworks | type == "array")
				and all(.ensureNetworks[]; (
					(.project | type == "string")
					and (.name | type == "string")
					and (.type | type == "string")
					and (.config | type == "object")
					and all(.config[]; type == "string")
				))
				and (.setNetworkConfig | type == "array")
				and all(.setNetworkConfig[]; (
					(.project | type == "string")
					and (.name | type == "string")
					and (.config | type == "object")
					and all(.config[]; type == "string")
					and (.unsetKeys | type == "array")
					and all(.unsetKeys[]; type == "string")
				))
				and (.ensureProjects | type == "array")
				and all(.ensureProjects[]; (
					(.name | type == "string")
					and (.config | type == "object")
					and all(.config[]; type == "string")
				))
				and (.ensureProfiles | type == "array")
				and all(.ensureProfiles[]; (
					(.project | type == "string")
					and (.name | type == "string")
					and (.config | type == "object")
					and all(.config[]; type == "string")
					and (.devices | type == "object")
					and all(.devices[]; (
						type == "object"
						and (.type | type == "string")
						and all(.[]; type == "string")
					))
				))
				and (.renameProjects | type == "array")
				and all(.renameProjects[]; (
					(.from | type == "string")
					and (.to | type == "string")
				))
				and (.renameNetworks | type == "array")
				and all(.renameNetworks[]; (
					(.project | type == "string")
					and (.from | type == "string")
					and (.to | type == "string")
				))
				and (.deleteNetworks | type == "array")
				and all(.deleteNetworks[]; (
					(.project | type == "string")
					and (.name | type == "string")
				))
				and (.setProfileDeviceProperties | type == "array")
				and all(.setProfileDeviceProperties[]; (
					(.project | type == "string")
					and (.profile | type == "string")
					and (.device | type == "string")
					and (.properties | type == "object")
					and all(.properties[]; type == "string")
				))
				and (.setInstanceDeviceProperties | type == "array")
				and all(.setInstanceDeviceProperties[]; (
					(.project | type == "string")
					and (.instance | type == "string")
					and (.device | type == "string")
					and (.properties | type == "object")
					and all(.properties[]; type == "string")
				))
				and (.setProjectConfig | type == "array")
				and all(.setProjectConfig[]; (
					(.project | type == "string")
					and (.config | type == "object")
					and all(.config[]; type == "string")
				))
				and (.moveInstancesToStoragePools | type == "array")
				and all(.moveInstancesToStoragePools[]; (
					(.project | type == "string")
					and (.name | type == "string")
					and ((.targetProject == null) or (.targetProject | type == "string"))
					and (.pool | type == "string")
				))
				and (.moveStorageVolumes | type == "array")
				and all(.moveStorageVolumes[]; (
					(.project | type == "string")
					and (.name | type == "string")
					and (.fromPool | type == "string")
					and ((.targetProject == null) or (.targetProject | type == "string"))
					and (.toPool | type == "string")
				))
				and (.stopInstances | type == "array")
				and all(.stopInstances[]; (
					(.project | type == "string")
					and (.name | type == "string")
				))
				and (.startInstances | type == "array")
				and all(.startInstances[]; (
					(.project | type == "string")
					and (.name | type == "string")
				))
				and (.deleteInstances | type == "array")
				and all(.deleteInstances[]; (
					(.project | type == "string")
					and (.name | type == "string")
				))
			))
		' >/dev/null

	migration_volume_attachments_file="$(mktemp /run/incus-preseed-volume-attachments.XXXXXX)"
	while IFS= read -r migration; do
		while IFS= read -r pool_json; do
			[ -n "$pool_json" ] || continue
			pool="$(printf '%s' "$pool_json" | jq -r '.name')"
			driver="$(printf '%s' "$pool_json" | jq -r '.driver')"
			pool_config_json="$(printf '%s' "$pool_json" | jq -c '.config')"
			pool_exists=0
			if incus storage show "$pool" >/dev/null 2>&1; then
				pool_exists=1
			fi

			create_pool_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$pool_config_json" | jq -r --arg k "$key" '.[$k]')"
				create_pool_args+=("$key=$value")
			done < <(printf '%s' "$pool_config_json" | jq -r 'keys[]')

			if [ "$pool_exists" -eq 0 ]; then
				incus storage create "$pool" "$driver" "${create_pool_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.ensureStoragePools[]')

		while IFS= read -r network_config_json; do
			[ -n "$network_config_json" ] || continue
			network_project="$(printf '%s' "$network_config_json" | jq -r '.project')"
			name="$(printf '%s' "$network_config_json" | jq -r '.name')"
			if ! incus network show --project "$network_project" "$name" >/dev/null 2>&1; then
				continue
			fi

			unset_keys_json="$(printf '%s' "$network_config_json" | jq -c '.unsetKeys')"
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				incus network unset --project "$network_project" "$name" "$key" || true
			done < <(printf '%s' "$unset_keys_json" | jq -r '.[]')

			set_network_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$network_config_json" | jq -r --arg k "$key" '.config[$k]')"
				set_network_args+=("$key=$value")
			done < <(printf '%s' "$network_config_json" | jq -r '.config | keys[]')

			if [ "${#set_network_args[@]}" -gt 0 ]; then
				incus network set --project "$network_project" "$name" "${set_network_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.setNetworkConfig[]')

		while IFS= read -r rename_network_json; do
			[ -n "$rename_network_json" ] || continue
			network_project="$(printf '%s' "$rename_network_json" | jq -r '.project')"
			from_network="$(printf '%s' "$rename_network_json" | jq -r '.from')"
			to_network="$(printf '%s' "$rename_network_json" | jq -r '.to')"
			if [ "$from_network" = "$to_network" ]; then
				continue
			fi

			source_exists=0
			target_exists=0
			incus network show --project "$network_project" "$from_network" >/dev/null 2>&1 && source_exists=1
			incus network show --project "$network_project" "$to_network" >/dev/null 2>&1 && target_exists=1

			if [ "$source_exists" -eq 1 ] && [ "$target_exists" -eq 1 ]; then
				if [ "$(incus network show --project "$network_project" "$from_network" --format=json | jq '(.used_by // []) | length')" -eq 0 ]; then
					incus network delete --project "$network_project" "$from_network"
					continue
				fi
				echo "Cannot rename Incus network $network_project/$from_network to $to_network: both networks exist" >&2
				exit 1
			fi
			if [ "$source_exists" -eq 1 ]; then
				incus network rename --project "$network_project" "$from_network" "$to_network"
			fi
		done < <(printf '%s' "$migration" | jq -c '.renameNetworks[]')

		while IFS= read -r network_json; do
			[ -n "$network_json" ] || continue
			network_project="$(printf '%s' "$network_json" | jq -r '.project')"
			name="$(printf '%s' "$network_json" | jq -r '.name')"
			device_type="$(printf '%s' "$network_json" | jq -r '.type')"
			network_config_json="$(printf '%s' "$network_json" | jq -c '.config')"

			if incus network show --project "$network_project" "$name" >/dev/null 2>&1; then
				continue
			fi

			create_network_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$network_config_json" | jq -r --arg k "$key" '.[$k]')"
				create_network_args+=("$key=$value")
			done < <(printf '%s' "$network_config_json" | jq -r 'keys[]')

			incus network create --project "$network_project" "$name" --type "$device_type" "${create_network_args[@]}"
		done < <(printf '%s' "$migration" | jq -c '.ensureNetworks[]')

		while IFS= read -r project_json; do
			[ -n "$project_json" ] || continue
			project="$(printf '%s' "$project_json" | jq -r '.name')"
			project_config_json="$(printf '%s' "$project_json" | jq -c '.config')"
			project_exists=0
			if incus project show "$project" >/dev/null 2>&1; then
				project_exists=1
			fi

			create_project_args=()
			set_project_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$project_config_json" | jq -r --arg k "$key" '.[$k]')"
				create_project_args+=("--config" "$key=$value")
				set_project_args+=("$key=$value")
			done < <(printf '%s' "$project_config_json" | jq -r 'keys[]')

			if [ "$project_exists" -eq 0 ]; then
				incus project create "$project" "${create_project_args[@]}"
			fi

			if [ "${#set_project_args[@]}" -gt 0 ]; then
				incus project set "$project" "${set_project_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.ensureProjects[]')

		while IFS= read -r instance_device_json; do
			[ -n "$instance_device_json" ] || continue
			project="$(printf '%s' "$instance_device_json" | jq -r '.project')"
			instance="$(printf '%s' "$instance_device_json" | jq -r '.instance')"
			device="$(printf '%s' "$instance_device_json" | jq -r '.device')"
			encoded_instance="$(jq -nr --arg value "$instance" '$value | @uri')"

			current_project="$project"
			if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
				continue
			fi
			if ! printf '%s' "$instance_config_json" | jq -e --arg device "$device" '(.metadata.devices // .devices // {}) | has($device)' >/dev/null 2>&1; then
				continue
			fi

			set_device_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$instance_device_json" | jq -r --arg k "$key" '.properties[$k]')"
				set_device_args+=("$key=$value")
			done < <(printf '%s' "$instance_device_json" | jq -r '.properties | keys[]')

			if [ "${#set_device_args[@]}" -gt 0 ]; then
				incus config device set --project "$project" "$instance" "$device" "${set_device_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.setInstanceDeviceProperties[]')

		while IFS= read -r profile_json; do
			[ -n "$profile_json" ] || continue
			project="$(printf '%s' "$profile_json" | jq -r '.project')"
			profile="$(printf '%s' "$profile_json" | jq -r '.name')"
			profile_config_json="$(printf '%s' "$profile_json" | jq -c '.config')"
			encoded_profile="$(jq -nr --arg value "$profile" '$value | @uri')"

			current_project="$project"
			if ! incus query "$(query_ref "/1.0/profiles/$encoded_profile")" --raw >/dev/null 2>&1; then
				incus profile create --project "$project" "$profile"
			fi

			set_profile_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$profile_config_json" | jq -r --arg k "$key" '.[$k]')"
				set_profile_args+=("$key=$value")
			done < <(printf '%s' "$profile_config_json" | jq -r 'keys[]')

			if [ "${#set_profile_args[@]}" -gt 0 ]; then
				incus profile set --project "$project" "$profile" "${set_profile_args[@]}"
			fi

			while IFS= read -r device; do
				[ -n "$device" ] || continue
				device_json="$(printf '%s' "$profile_json" | jq -c --arg device "$device" '.devices[$device]')"
				device_type="$(printf '%s' "$device_json" | jq -r '.type')"
				set_device_args=()
				while IFS= read -r key; do
					[ -n "$key" ] || continue
					value="$(printf '%s' "$device_json" | jq -r --arg k "$key" '.[$k]')"
					set_device_args+=("$key=$value")
				done < <(printf '%s' "$device_json" | jq -r 'keys[] | select(. != "type")')

				if incus profile device get --project "$project" "$profile" "$device" type >/dev/null 2>&1; then
					incus profile device set --project "$project" "$profile" "$device" "${set_device_args[@]}"
				else
					incus profile device add --project "$project" "$profile" "$device" "$device_type" "${set_device_args[@]}"
				fi
			done < <(printf '%s' "$profile_json" | jq -r '.devices | keys[]')
		done < <(printf '%s' "$migration" | jq -c '.ensureProfiles[]')

		while IFS= read -r rename_project_json; do
			[ -n "$rename_project_json" ] || continue
			from_project="$(printf '%s' "$rename_project_json" | jq -r '.from')"
			to_project="$(printf '%s' "$rename_project_json" | jq -r '.to')"
			if [ "$from_project" = "$to_project" ]; then
				continue
			fi

			source_exists=0
			target_exists=0
			incus project show "$from_project" >/dev/null 2>&1 && source_exists=1
			incus project show "$to_project" >/dev/null 2>&1 && target_exists=1

			if [ "$source_exists" -eq 1 ] && [ "$target_exists" -eq 1 ]; then
				echo "Cannot rename Incus project $from_project to $to_project: both projects exist" >&2
				exit 1
			fi
			if [ "$source_exists" -eq 1 ]; then
				incus project rename "$from_project" "$to_project"
			fi
		done < <(printf '%s' "$migration" | jq -c '.renameProjects[]')

		while IFS= read -r project_config_migration_json; do
			[ -n "$project_config_migration_json" ] || continue
			project="$(printf '%s' "$project_config_migration_json" | jq -r '.project')"
			if ! incus project show "$project" >/dev/null 2>&1; then
				continue
			fi

			project_config_json="$(printf '%s' "$project_config_migration_json" | jq -c '.config')"
			set_project_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$project_config_json" | jq -r --arg k "$key" '.[$k]')"
				set_project_args+=("$key=$value")
			done < <(printf '%s' "$project_config_json" | jq -r 'keys[]')

			if [ "${#set_project_args[@]}" -gt 0 ]; then
				incus project set "$project" "${set_project_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.setProjectConfig[]')

		while IFS= read -r stop_instance_json; do
			[ -n "$stop_instance_json" ] || continue
			project="$(printf '%s' "$stop_instance_json" | jq -r '.project')"
			name="$(printf '%s' "$stop_instance_json" | jq -r '.name')"
			encoded_instance="$(jq -nr --arg value "$name" '$value | @uri')"
			current_project="$project"
			if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
				continue
			fi

			status="$(printf '%s' "$instance_config_json" | jq -r '.metadata.status // .status // ""')"
			if [ "$status" = "Running" ]; then
				incus --project "$project" stop "$name" --force
			fi
		done < <(printf '%s' "$migration" | jq -c '.stopInstances[]')

		while IFS= read -r volume_json; do
			[ -n "$volume_json" ] || continue
			project="$(printf '%s' "$volume_json" | jq -r '.project')"
			name="$(printf '%s' "$volume_json" | jq -r '.name')"
			from_pool="$(printf '%s' "$volume_json" | jq -r '.fromPool')"
			to_pool="$(printf '%s' "$volume_json" | jq -r '.toPool')"
			target_project="$(printf '%s' "$volume_json" | jq -r '.targetProject // .project')"

			if [ "$from_pool" = "$to_pool" ] && [ "$project" = "$target_project" ]; then
				continue
			fi
			source_exists=0
			target_exists=0
			incus storage volume show --project "$project" "$from_pool" "$name" >/dev/null 2>&1 && source_exists=1
			incus storage volume show --project "$target_project" "$to_pool" "$name" >/dev/null 2>&1 && target_exists=1
			if [ "$target_exists" -eq 1 ]; then
				continue
			fi
			if [ "$source_exists" -eq 0 ]; then
				continue
			fi
			record_moved_volume_attachments "$project" "$target_project" "$from_pool" "$to_pool" "$name"
			move_volume_args=(--project "$project" "$from_pool/$name" "$to_pool/$name")
			if [ "$target_project" != "$project" ]; then
				move_volume_args+=(--target-project "$target_project")
			fi
			incus storage volume move "${move_volume_args[@]}"
		done < <(printf '%s' "$migration" | jq -c '.moveStorageVolumes[]')

		while IFS= read -r instance_json; do
			[ -n "$instance_json" ] || continue
			project="$(printf '%s' "$instance_json" | jq -r '.project')"
			name="$(printf '%s' "$instance_json" | jq -r '.name')"
			target_project="$(printf '%s' "$instance_json" | jq -r '.targetProject // .project')"
			pool="$(printf '%s' "$instance_json" | jq -r '.pool')"
			encoded_instance="$(jq -nr --arg value "$name" '$value | @uri')"

			if [ "$target_project" != "$project" ]; then
				current_project="$target_project"
				if target_instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
					if ! query_response_is_error "$target_instance_config_json"; then
						reattach_moved_volume_devices "$project" "$target_project" "$name"
						continue
					fi
				fi
			fi

			current_project="$project"
			if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
				continue
			fi
			if query_response_is_error "$instance_config_json"; then
				continue
			fi
			root_pool="$(printf '%s' "$instance_config_json" | jq -r '.metadata.expanded_devices.root.pool // .expanded_devices.root.pool // ""')"
			if [ "$root_pool" = "$pool" ] && [ "$project" = "$target_project" ]; then
				continue
			fi

			status="$(printf '%s' "$instance_config_json" | jq -r '.metadata.status // .status // ""')"
			if [ "$status" = "Running" ]; then
				incus --project "$project" stop "$name" --force
			fi
			move_instance_args=(--project "$project" "$name" "$name" --storage "$pool")
			if [ "$target_project" != "$project" ]; then
				move_instance_args+=(--target-project "$target_project")
				incus copy "${move_instance_args[@]}"
			else
				incus move "${move_instance_args[@]}"
			fi
			reattach_moved_volume_devices "$project" "$target_project" "$name"
		done < <(printf '%s' "$migration" | jq -c '.moveInstancesToStoragePools[]')

		while IFS= read -r delete_instance_json; do
			[ -n "$delete_instance_json" ] || continue
			project="$(printf '%s' "$delete_instance_json" | jq -r '.project')"
			name="$(printf '%s' "$delete_instance_json" | jq -r '.name')"
			encoded_instance="$(jq -nr --arg value "$name" '$value | @uri')"
			current_project="$project"
			if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
				continue
			fi
			if query_response_is_error "$instance_config_json"; then
				continue
			fi
			status="$(printf '%s' "$instance_config_json" | jq -r '.metadata.status // .status // ""')"
			if [ "$status" = "Running" ]; then
				incus --project "$project" stop "$name" --force
			fi
			incus delete --project "$project" "$name" --force
		done < <(printf '%s' "$migration" | jq -c '.deleteInstances[]')

		while IFS= read -r instance_device_json; do
			[ -n "$instance_device_json" ] || continue
			project="$(printf '%s' "$instance_device_json" | jq -r '.project')"
			instance="$(printf '%s' "$instance_device_json" | jq -r '.instance')"
			device="$(printf '%s' "$instance_device_json" | jq -r '.device')"
			encoded_instance="$(jq -nr --arg value "$instance" '$value | @uri')"

			current_project="$project"
			if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
				continue
			fi
			if ! printf '%s' "$instance_config_json" | jq -e --arg device "$device" '(.metadata.devices // .devices // {}) | has($device)' >/dev/null 2>&1; then
				continue
			fi

			set_device_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$instance_device_json" | jq -r --arg k "$key" '.properties[$k]')"
				set_device_args+=("$key=$value")
			done < <(printf '%s' "$instance_device_json" | jq -r '.properties | keys[]')

			if [ "${#set_device_args[@]}" -gt 0 ]; then
				incus config device set --project "$project" "$instance" "$device" "${set_device_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.setInstanceDeviceProperties[]')

		while IFS= read -r profile_device_json; do
			[ -n "$profile_device_json" ] || continue
			project="$(printf '%s' "$profile_device_json" | jq -r '.project')"
			profile="$(printf '%s' "$profile_device_json" | jq -r '.profile')"
			device="$(printf '%s' "$profile_device_json" | jq -r '.device')"
			encoded_profile="$(jq -nr --arg value "$profile" '$value | @uri')"

			current_project="$project"
			if ! profile_json="$(incus query "$(query_ref "/1.0/profiles/$encoded_profile")" --raw 2>/dev/null)"; then
				continue
			fi
			if ! printf '%s' "$profile_json" | jq -e --arg device "$device" '(.devices // .metadata.devices // {}) | has($device)' >/dev/null 2>&1; then
				continue
			fi

			set_profile_args=()
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				value="$(printf '%s' "$profile_device_json" | jq -r --arg k "$key" '.properties[$k]')"
				set_profile_args+=("$key=$value")
			done < <(printf '%s' "$profile_device_json" | jq -r '.properties | keys[]')

			if [ "${#set_profile_args[@]}" -gt 0 ]; then
				incus profile device set --project "$project" "$profile" "$device" "${set_profile_args[@]}"
			fi
		done < <(printf '%s' "$migration" | jq -c '.setProfileDeviceProperties[]')

		while IFS= read -r delete_network_json; do
			[ -n "$delete_network_json" ] || continue
			network_project="$(printf '%s' "$delete_network_json" | jq -r '.project')"
			name="$(printf '%s' "$delete_network_json" | jq -r '.name')"
			if incus network show --project "$network_project" "$name" >/dev/null 2>&1; then
				incus network delete --project "$network_project" "$name"
			fi
		done < <(printf '%s' "$migration" | jq -c '.deleteNetworks[]')

		while IFS= read -r start_instance_json; do
			[ -n "$start_instance_json" ] || continue
			project="$(printf '%s' "$start_instance_json" | jq -r '.project')"
			name="$(printf '%s' "$start_instance_json" | jq -r '.name')"
			encoded_instance="$(jq -nr --arg value "$name" '$value | @uri')"
			current_project="$project"
			if ! instance_config_json="$(incus query "$(query_ref "/1.0/instances/$encoded_instance")" --raw 2>/dev/null)"; then
				continue
			fi
			if query_response_is_error "$instance_config_json"; then
				continue
			fi
			status="$(printf '%s' "$instance_config_json" | jq -r '.metadata.status // .status // ""')"
			if [ "$status" != "Running" ]; then
				incus start --project "$project" "$name"
			fi
		done < <(printf '%s' "$migration" | jq -c '.startInstances[]')

		prefixes_json="$(printf '%s' "$migration" | jq -c '.unsetInstanceConfigKeyPrefixes')"
		if [ "$prefixes_json" = "[]" ]; then
			continue
		fi

		while IFS= read -r project; do
			[ -n "$project" ] || continue
			if ! incus project show "$project" >/dev/null 2>&1; then
				continue
			fi

			current_project="$project"
			project_instances="$(incus_project list --format=json)"
			while IFS= read -r instance; do
				[ -n "$instance" ] || continue
				instance_config_json="$(incus query "$(query_ref "$(instance_query_path "$instance")")")"
				keys_json="$(
					printf '%s' "$instance_config_json" |
						jq -c --argjson prefixes "$prefixes_json" '
							[
								.config // {}
								| keys[] as $key
								| select(any($prefixes[]; . as $prefix | $key | startswith($prefix)))
								| $key
							]
						'
				)"

				while IFS= read -r key; do
					[ -n "$key" ] || continue
					incus config unset --project "$project" "$instance" "$key" || true
				done < <(printf '%s' "$keys_json" | jq -r '.[]')
			done < <(printf '%s' "$project_instances" | jq -r '.[].name')
		done < <(printf '%s' "$migration" | jq -r '.projects[]')
	done < <(printf '%s' "$preseed_migrations" | jq -c '.[]')
	rm -f -- "$migration_volume_attachments_file"
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

	incus_project config device add "$(instance_ref "$instance_name")" "$device_name" "$device_type" "${add_args[@]}"
}

add_device_from_props_idempotent() {
	local instance_name device_name props_json output

	instance_name="$1"
	device_name="$2"
	props_json="$3"

	if output="$(add_device_from_props "$instance_name" "$device_name" "$props_json" 2>&1)"; then
		[ -z "$output" ] || printf '%s\n' "$output"
		return 0
	fi

	if printf '%s' "$output" | grep -qi 'device already exists'; then
		echo "Device $device_name already exists on $instance_name; continuing"
		return 0
	fi

	printf '%s\n' "$output" >&2
	return 1
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

instance_accepts_exec() {
	local name cmd
	name="$1"

	for cmd in \
		/nix/var/nix/profiles/system/sw/bin/true \
		/run/current-system/sw/bin/true \
		/usr/bin/true \
		/bin/true; do
		if incus_project_timeout 10 exec "$(instance_ref "$name")" -- "$cmd" >/dev/null 2>&1; then
			return 0
		fi
	done

	return 1
}

instance_reconcile_guest_network() {
	local name bin attempted
	name="$1"
	attempted=1

	for bin in /nix/var/nix/profiles/system/sw/bin /run/current-system/sw/bin; do
		if incus_project_timeout 10 exec "$(instance_ref "$name")" -- "$bin/networkctl" reload >/dev/null 2>&1; then
			attempted=0
			incus_project_timeout 10 exec "$(instance_ref "$name")" -- "$bin/networkctl" reconfigure eth0 >/dev/null 2>&1 || true
		fi

		if incus_project_timeout 10 exec "$(instance_ref "$name")" -- "$bin/systemctl" restart systemd-networkd.service >/dev/null 2>&1; then
			attempted=0
		fi
	done

	return "$attempted"
}

apply_instance_config_json() {
	local instance_name config_json entry key value
	local -a set_args=()
	instance_name="$1"
	config_json="$2"

	while IFS= read -r entry; do
		key="$(printf '%s' "$entry" | jq -r '.key')"
		value="$(printf '%s' "$entry" | jq -r '.value')"
		set_args+=("$key=$value")
	done < <(printf '%s' "$config_json" | jq -c 'to_entries[]')

	if [ "${#set_args[@]}" -gt 0 ]; then
		incus_project config set "$(instance_ref "$instance_name")" "${set_args[@]}"
	fi
}

set_instance_config_json_if_changed() {
	local instance_name current_config_json desired_config_json entry key current_value desired_value
	local -a set_args=()
	instance_name="$1"
	current_config_json="$2"
	desired_config_json="$3"

	while IFS= read -r entry; do
		key="$(printf '%s' "$entry" | jq -r '.key')"
		desired_value="$(printf '%s' "$entry" | jq -r '.value')"
		current_value="$(printf '%s' "$current_config_json" | jq -r --arg k "$key" '.[$k] // empty')"
		if [ "$current_value" != "$desired_value" ]; then
			set_args+=("$key=$desired_value")
		fi
	done < <(printf '%s' "$desired_config_json" | jq -c 'to_entries[]')

	if [ "${#set_args[@]}" -gt 0 ]; then
		incus_project config set "$(instance_ref "$instance_name")" "${set_args[@]}"
	fi
}

unset_instance_config_key_if_present() {
	local instance_name current_config_json key
	instance_name="$1"
	current_config_json="$2"
	key="$3"

	if printf '%s' "$current_config_json" | jq -e --arg k "$key" 'has($k)' >/dev/null; then
		incus_project config unset "$(instance_ref "$instance_name")" "$key" 2>/dev/null || true
	fi
}

set_device_config_json_if_changed() {
	local instance_name device current_props desired_props entry key current_value desired_value
	local -a set_args=()
	instance_name="$1"
	device="$2"
	current_props="$3"
	desired_props="$4"

	while IFS= read -r entry; do
		key="$(printf '%s' "$entry" | jq -r '.key')"
		desired_value="$(printf '%s' "$entry" | jq -r '.value')"
		current_value="$(printf '%s' "$current_props" | jq -r --arg k "$key" '.[$k] // empty')"
		if [ "$current_value" != "$desired_value" ]; then
			set_args+=("$key=$desired_value")
		fi
	done < <(printf '%s' "$desired_props" | jq -c 'to_entries[]')

	if [ "${#set_args[@]}" -gt 0 ]; then
		incus_project config device set "$(instance_ref "$instance_name")" "$device" "${set_args[@]}"
	fi
}

guest_id_host_id_from_config() {
	local config_json kind guest_id idmap
	config_json="$1"
	kind="$2"
	guest_id="$3"

	idmap="$(
		printf '%s' "$config_json" |
			jq -r '."volatile.idmap.current" // ."volatile.idmap.next" // empty'
	)"
	[ -n "$idmap" ] || return 1

	case "$kind" in
	uid | gid) ;;
	*)
		return 1
		;;
	esac

	printf '%s' "$idmap" |
		jq -r --arg kind "$kind" --argjson guest_id "$guest_id" '
			(if type == "string" then (fromjson? // []) else . end)
			| map(select(
				((($kind == "uid") and (.Isuid == true))
				or (($kind == "gid") and (.Isgid == true)))
				and (($guest_id >= (.Nsid | tonumber))
				and ($guest_id < ((.Nsid | tonumber) + (.Maprange | tonumber))))
			))
			| first
			| if . == null then
				empty
			else
				((.Hostid | tonumber) + ($guest_id - (.Nsid | tonumber)))
			end
		'
}

prepare_certificate_delegation_permissions() {
	local config_json disk_gc_metadata host_uid host_gid entry source file_name file_path
	config_json="$1"
	disk_gc_metadata="$2"

	while IFS= read -r entry; do
		source="$(printf '%s' "$entry" | jq -r '.value.source // empty')"
		file_name="$(printf '%s' "$entry" | jq -r '.value.fileName // "certs.json"')"
		[ -n "$source" ] || continue
		[ -d "$source" ] || continue

		host_uid="$(guest_id_host_id_from_config "$config_json" uid 0 || true)"
		host_gid="$(guest_id_host_id_from_config "$config_json" gid 0 || true)"
		[ -n "$host_uid" ] || continue
		[ -n "$host_gid" ] || continue

		echo "  Setting certificate delegation $source ownership to guest root"
		chown "$host_uid:$host_gid" "$source"
		chmod 0700 "$source"

		file_path="$source/$file_name"
		if [ -e "$file_path" ]; then
			chown "$host_uid:$host_gid" "$file_path"
			chmod 0600 "$file_path"
		fi
	done < <(
		printf '%s' "$disk_gc_metadata" |
			jq -c 'to_entries[] | select(.value.certificateDelegation == true)'
	)
}

is_safe_gc_removal_dir() {
	local dir real_dir
	dir="$1"

	[ -n "$dir" ] || return 1
	real_dir="$(realpath -e -- "$dir")" || return 1
	case "$real_dir" in
	"$managed_gc_dir_root" | "$managed_gc_dir_root/" | "$managed_gc_dir_root"/*)
		[ "$real_dir" != "$managed_gc_dir_root" ]
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

	if delete_output="$(incus_project delete "$(instance_ref "$instance_name")" --force 2>&1)"; then
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
	incus_project delete "$(instance_ref "$instance_name")" --force
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

make_certificates_tmpdir() {
	# Callers may run in command substitutions; this state and trap are scoped to
	# the shell process that owns the temp files.
	if [ -n "${certificates_tmpdir-}" ]; then
		echo "Nested Incus certificate tempdir allocation is not supported" >&2
		exit 1
	fi
	certificates_tmpdir_saved_exit_trap="$(trap -p EXIT || true)"
	certificates_tmpdir="$(mktemp -d)"
	trap cleanup_certificates_tmpdir EXIT
}

cleanup_certificates_tmpdir() {
	if [ -n "${certificates_tmpdir-}" ]; then
		rm -rf -- "$certificates_tmpdir"
		certificates_tmpdir=""
	fi
	if [ -n "${certificates_tmpdir_saved_exit_trap-}" ]; then
		eval "$certificates_tmpdir_saved_exit_trap"
	else
		trap - EXIT
	fi
	certificates_tmpdir_saved_exit_trap=""
}

desired_certificates_state() {
	local cert_file cert_json fingerprint name tmpdir
	local index=0

	printf '%s' "$certificates" | jq -e 'type == "array"' >/dev/null

	make_certificates_tmpdir
	tmpdir="$certificates_tmpdir"

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

	cleanup_certificates_tmpdir
}

remove_trusted_certificates() {
	local live_trust match matches removal_state_json
	removal_state_json="$1"

	if is_remote_target; then
		live_trust="$(incus config trust list "$(server_ref)" --format=json)"
	else
		live_trust="$(incus config trust list --format=json)"
	fi
	# Names are module-owned, so matching by name intentionally replaces
	# certificates across rotations.
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
			incus config trust remove "${incus_remote_name}:$match" || {
				echo "Trusted Incus certificate $match was already absent during reconcile"
			}
		else
			incus config trust remove "$match" || {
				echo "Trusted Incus certificate $match was already absent during reconcile"
			}
		fi
	done <<<"$matches"
}

remove_trusted_certificates_by_name() {
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
					select(any($removal[]; .name == $entry.name)) |
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
			incus config trust remove "${incus_remote_name}:$match" || {
				echo "Trusted Incus certificate $match was already absent during reconcile"
			}
		else
			incus config trust remove "$match" || {
				echo "Trusted Incus certificate $match was already absent during reconcile"
			}
		fi
	done <<<"$matches"
}

previous_certificates_state() {
	if [ -s "$certificates_state_file" ]; then
		jq -c '[.[] | {name, fingerprint}]' "$certificates_state_file"
	else
		printf '[]\n'
	fi
}

add_declared_certificates() {
	local cert_file cert_json name projects restricted tmpdir type
	local index=0

	make_certificates_tmpdir
	tmpdir="$certificates_tmpdir"

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

	cleanup_certificates_tmpdir
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

read_certificate_delegation_payload() {
	if [ ! -s "$certificate_delegation_source_file" ]; then
		jq -cn '{version: 1, certificates: []}'
		return
	fi

	if ! jq -e \
		--argjson max "$certificate_delegation_max_certificates" '
			type == "object"
			and .version == 1
			and (.certificates | type == "array")
			and (.certificates | length <= $max)
			and all(.certificates[]; (
				type == "object"
				and (.name | type == "string")
				and (.data | type == "string")
			))
		' "$certificate_delegation_source_file" >/dev/null; then
		echo "Delegated Incus certificate file $certificate_delegation_source_file is invalid" >&2
		exit 1
	fi

	jq -c '{version, certificates}' "$certificate_delegation_source_file"
}

validate_certificate_delegation_name() {
	local full_name tenant_name
	tenant_name="$1"
	full_name="${certificate_delegation_name_prefix}${tenant_name}"

	if ! [[ "$tenant_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]]; then
		echo "Delegated Incus certificate name '$tenant_name' is invalid" >&2
		exit 1
	fi

	if [ "${#full_name}" -gt 120 ]; then
		echo "Delegated Incus certificate name '$full_name' is too long" >&2
		exit 1
	fi
}

desired_certificate_delegation_state() {
	local cert_file cert_json data fingerprint full_name payload tenant_name tmpdir
	local index=0
	payload="$1"

	make_certificates_tmpdir
	tmpdir="$certificates_tmpdir"

	printf '['
	while IFS= read -r cert_json; do
		tenant_name="$(printf '%s' "$cert_json" | jq -r '.name')"
		validate_certificate_delegation_name "$tenant_name"
		full_name="${certificate_delegation_name_prefix}${tenant_name}"
		cert_file="$tmpdir/cert-${index}.pem"
		data="$(printf '%s' "$cert_json" | jq -r '.data')"
		printf '%s' "$data" >"$cert_file"

		if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
			echo "Delegated Incus certificate '$tenant_name' is not a valid PEM certificate" >&2
			exit 1
		fi

		fingerprint="$(certificate_fingerprint "$cert_file")"
		[ "$index" -eq 0 ] || printf ','
		jq -cn \
			--arg name "$full_name" \
			--arg tenantName "$tenant_name" \
			--arg fingerprint "$fingerprint" \
			--arg data "$data" \
			'{name: $name, tenantName: $tenantName, fingerprint: $fingerprint, data: $data}'
		index=$((index + 1))
	done < <(printf '%s' "$payload" | jq -c '.certificates[]')
	printf ']\n'
	cleanup_certificates_tmpdir
}

validate_certificate_delegation_state() {
	local desired_state
	desired_state="$1"

	if ! jq -e '
		([.[].name] | length == (unique | length))
		and ([.[].fingerprint] | length == (unique | length))
	' <<<"$desired_state" >/dev/null; then
		echo "Delegated Incus certificate file contains duplicate names or certificates" >&2
		exit 1
	fi
}

previous_certificate_delegation_state() {
	if [ -s "$certificate_delegation_state_file" ]; then
		jq -c '[.[] | {name, fingerprint}]' "$certificate_delegation_state_file"
	else
		printf '[]\n'
	fi
}

trusted_certificate_json_by_fingerprint() {
	local fingerprint
	fingerprint="$1"

	incus config trust list --format=json |
		jq -c --arg fp "$fingerprint" '.[] | select(.fingerprint == $fp)' |
		head -n1
}

add_project_to_trusted_certificate() {
	local fingerprint project trust_payload
	fingerprint="$1"
	project="$2"

	trust_payload="$(
		incus query "/1.0/certificates/$fingerprint" |
			jq -c --arg project "$project" '
				.restricted = true
				| .projects = ([.projects[]?, $project] | unique)
			'
	)"
	incus query -X PUT -d "$trust_payload" "/1.0/certificates/$fingerprint" >/dev/null
}

remove_project_from_trusted_certificate() {
	local fingerprint project remaining_count remaining_projects trust_payload
	fingerprint="$1"
	project="$2"

	if ! trust_payload="$(incus query "/1.0/certificates/$fingerprint" 2>/dev/null)"; then
		echo "Delegated Incus trusted certificate $fingerprint was already absent during reconcile"
		return
	fi

	remaining_projects="$(
		printf '%s' "$trust_payload" |
			jq -c --arg project "$project" '[.projects[]? | select(. != $project)] | unique'
	)"
	remaining_count="$(printf '%s' "$remaining_projects" | jq -r 'length')"

	if [ "$remaining_count" -eq 0 ]; then
		echo "Removing delegated Incus trusted certificate $fingerprint after removing project $project"
		incus config trust remove "$fingerprint" || {
			echo "Delegated Incus trusted certificate $fingerprint was already absent during reconcile"
		}
		return
	fi

	echo "Removing project $project from delegated Incus trusted certificate $fingerprint"
	trust_payload="$(
		printf '%s' "$trust_payload" |
			jq -c --argjson projects "$remaining_projects" '.projects = $projects'
	)"
	incus query -X PUT -d "$trust_payload" "/1.0/certificates/$fingerprint" >/dev/null
}

remove_delegated_certificates_for_project() {
	local cert_json fingerprint project removal_state_json
	removal_state_json="$1"
	project="$2"

	while IFS= read -r cert_json; do
		[ -n "$cert_json" ] || continue
		fingerprint="$(printf '%s' "$cert_json" | jq -r '.fingerprint')"
		[ -n "$fingerprint" ] || continue
		remove_project_from_trusted_certificate "$fingerprint" "$project"
	done < <(printf '%s' "$removal_state_json" | jq -c '.[]')
}

add_delegated_certificates() {
	local add_output cert_file cert_json fingerprint live_entry name tmpdir
	local index=0

	make_certificates_tmpdir
	tmpdir="$certificates_tmpdir"

	while IFS= read -r cert_json; do
		name="$(printf '%s' "$cert_json" | jq -r '.name')"
		fingerprint="$(printf '%s' "$cert_json" | jq -r '.fingerprint')"
		cert_file="$tmpdir/cert-${index}.pem"
		printf '%s' "$cert_json" | jq -r '.data' >"$cert_file"

		live_entry="$(trusted_certificate_json_by_fingerprint "$fingerprint")"
		if [ -n "$live_entry" ]; then
			echo "Ensuring project $certificate_delegation_project on existing delegated Incus trusted certificate $fingerprint"
			add_project_to_trusted_certificate "$fingerprint" "$certificate_delegation_project"
			index=$((index + 1))
			continue
		fi

		echo "Adding delegated Incus trusted certificate $name for project $certificate_delegation_project"
		if add_output="$(incus config trust add-certificate "$cert_file" \
			--name "$name" \
			--type client \
			--restricted \
			--projects "$certificate_delegation_project" 2>&1)"; then
			index=$((index + 1))
			continue
		fi

		live_entry="$(trusted_certificate_json_by_fingerprint "$fingerprint")"
		if [ -z "$live_entry" ]; then
			for _attempt in 1 2 3 4 5; do
				sleep 1
				live_entry="$(trusted_certificate_json_by_fingerprint "$fingerprint")"
				[ -z "$live_entry" ] || break
			done
		fi
		if [ -z "$live_entry" ]; then
			printf '%s\n' "$add_output" >&2
			echo "Failed to add delegated Incus trusted certificate $name" >&2
			exit 1
		fi

		echo "Ensuring project $certificate_delegation_project on existing delegated Incus trusted certificate $fingerprint"
		add_project_to_trusted_certificate "$fingerprint" "$certificate_delegation_project"
		index=$((index + 1))
	done < <(printf '%s' "$1" | jq -c '.[]')

	cleanup_certificates_tmpdir
}

commit_certificate_delegation_state() {
	local desired_public_state state_dir tmp_file
	desired_public_state="$1"

	state_dir="$(dirname "$certificate_delegation_state_file")"
	mkdir -p "$state_dir"
	tmp_file="$(mktemp "${certificate_delegation_state_file}.tmp.XXXXXX")"
	printf '%s\n' "$desired_public_state" >"$tmp_file"
	chmod 0644 "$tmp_file"
	mv -f "$tmp_file" "$certificate_delegation_state_file"
}

certificate_delegation_main() {
	local desired_public_state desired_state payload previous_state removal_state

	[ -n "$certificate_delegation_name" ] || {
		echo "Missing delegated Incus certificate delegation name" >&2
		exit 1
	}
	[ -n "$certificate_delegation_project" ] || {
		echo "Missing delegated Incus certificate project for $certificate_delegation_name" >&2
		exit 1
	}
	[ -n "$certificate_delegation_source_file" ] || {
		echo "Missing delegated Incus certificate source file for $certificate_delegation_name" >&2
		exit 1
	}
	[ -n "$certificate_delegation_state_file" ] || {
		echo "Missing delegated Incus certificate state file for $certificate_delegation_name" >&2
		exit 1
	}
	[ -n "$certificate_delegation_name_prefix" ] || {
		echo "Missing delegated Incus certificate name prefix for $certificate_delegation_name" >&2
		exit 1
	}
	if ! [[ "$certificate_delegation_max_certificates" =~ ^[0-9]+$ ]]; then
		echo "Invalid delegated Incus certificate maximum for $certificate_delegation_name" >&2
		exit 1
	fi

	payload="$(read_certificate_delegation_payload)"
	desired_state="$(desired_certificate_delegation_state "$payload")"
	validate_certificate_delegation_state "$desired_state"
	desired_public_state="$(printf '%s' "$desired_state" | jq -c '[.[] | {name, tenantName, fingerprint}]')"
	previous_state="$(previous_certificate_delegation_state)"

	if ! incus_server_info >/dev/null 2>&1; then
		echo "Incus daemon is unavailable; delegated certificate reconcile cannot continue" >&2
		exit 1
	fi

	removal_state="$(
		jq -cn \
			--argjson previous "$previous_state" \
			--argjson desired "$desired_public_state" '
				$previous |
				map(select(.fingerprint as $fp | all($desired[]; .fingerprint != $fp)))
			'
	)"
	remove_delegated_certificates_for_project "$removal_state" "$certificate_delegation_project"
	add_delegated_certificates "$desired_state"
	commit_certificate_delegation_state "$desired_public_state"
}

previous_certificate_delegations_state() {
	if [ -s "$certificate_delegations_state_file" ]; then
		jq -c 'if type == "object" then . else {} end' "$certificate_delegations_state_file"
	else
		printf '{}\n'
	fi
}

is_safe_certificate_delegation_dir() {
	local dir real_dir root
	dir="$1"
	root="$certificate_delegations_root"

	[ -n "$dir" ] || return 1
	[ -n "$root" ] || return 1
	real_dir="$(realpath -e -- "$dir")" || return 1
	root="$(realpath -e -- "$root")" || return 1
	case "$real_dir" in
	"$root" | "$root/" | "$root"/*)
		[ "$real_dir" != "$root" ]
		;;
	*)
		return 1
		;;
	esac
}

commit_certificate_delegations_state() {
	local state_dir tmp_file

	state_dir="$(dirname "$certificate_delegations_state_file")"
	mkdir -p "$state_dir"
	tmp_file="$(mktemp "${certificate_delegations_state_file}.tmp.XXXXXX")"
	printf '%s\n' "$certificate_delegations" | jq -c . >"$tmp_file"
	chmod 0644 "$tmp_file"
	mv -f "$tmp_file" "$certificate_delegations_state_file"
}

certificate_delegations_gc_main() {
	local delegation directory previous previous_entry project removed_json state_file

	printf '%s' "$certificate_delegations" | jq -e 'type == "object"' >/dev/null || {
		echo "Declared Incus certificate delegations must be a JSON object" >&2
		exit 1
	}

	if ! incus_server_info >/dev/null 2>&1; then
		echo "Incus daemon is unavailable; delegated certificate GC cannot continue" >&2
		exit 1
	fi

	previous="$(previous_certificate_delegations_state)"
	removed_json="$(
		jq -cn \
			--argjson previous "$previous" \
			--argjson desired "$certificate_delegations" '
				$previous
				| to_entries
				| map(select(.key as $name | $desired[$name] == null))
			'
	)"

	while IFS= read -r previous_entry; do
		[ -n "$previous_entry" ] || continue

		delegation="$(printf '%s' "$previous_entry" | jq -r '.key')"
		directory="$(printf '%s' "$previous_entry" | jq -r '.value.directory // empty')"
		project="$(printf '%s' "$previous_entry" | jq -r '.value.project // empty')"
		state_file="$(printf '%s' "$previous_entry" | jq -r '.value.stateFile // empty')"

		if [ -n "$state_file" ] && [ -s "$state_file" ]; then
			echo "Removing delegated Incus trusted certificates for removed delegation $delegation"
			if [ -n "$project" ]; then
				remove_delegated_certificates_for_project "$(jq -c '[.[] | {name, fingerprint}]' "$state_file")" "$project"
			else
				remove_trusted_certificates_by_name "$(jq -c '[.[] | {name, fingerprint}]' "$state_file")"
			fi
			rm -f -- "$state_file"
		fi

		if is_safe_certificate_delegation_dir "$directory" && [ -d "$directory" ]; then
			echo "Removing delegated Incus certificate directory $directory"
			rm -rf -- "$directory"
		fi
	done < <(printf '%s' "$removed_json" | jq -c '.[]')

	commit_certificate_delegations_state
}

remote_project_delegations_wait_for_trust() {
	local wait_timeout project api_url
	local -a curl_trust_args=()
	wait_timeout="$1"
	project="$2"

	if [ -n "$incus_remote_server_cert_file" ]; then
		curl_trust_args=(--cacert "$incus_remote_server_cert_file")
	elif [ "$incus_remote_accept_certificate" = "true" ]; then
		curl_trust_args=(--insecure)
	fi

	api_url="${incus_remote_address%/}/1.0/instances?project=${project}"
	for _attempt in $(seq 1 "$wait_timeout"); do
		if curl \
			--silent \
			--fail \
			"${curl_trust_args[@]}" \
			--cert "$incus_remote_client_cert_file" \
			--key "$incus_remote_client_key_file" \
			"$api_url" >/dev/null; then
			return 0
		fi
		sleep 1
	done

	echo "Timed out waiting for parent Incus to authorize delegated client certificate for project $project" >&2
	exit 1
}

remote_project_delegations_main() {
	local cert_file cert_json cert_name certs_tmp directory file_name next_tmp project_json target tmp wait_timeout

	[ -n "$remote_project_delegations_file" ] || {
		echo "Missing remote project delegations file" >&2
		exit 1
	}

	while IFS= read -r project_json; do
		directory="$(printf '%s' "$project_json" | jq -r '.directory')"
		file_name="$(printf '%s' "$project_json" | jq -r '.fileName')"
		target="$directory/$file_name"

		install -d -m 0755 "$directory"
		certs_tmp="$(mktemp "$target.certs.XXXXXX")"
		printf '[]\n' >"$certs_tmp"

		while IFS= read -r cert_json; do
			cert_name="$(printf '%s' "$cert_json" | jq -r '.name')"
			cert_file="$(printf '%s' "$cert_json" | jq -r '.file')"
			next_tmp="$(mktemp "$target.certs.XXXXXX")"
			jq \
				--arg name "$cert_name" \
				--rawfile data "$cert_file" \
				'. + [{name: $name, data: $data}]' \
				"$certs_tmp" >"$next_tmp"
			mv -f "$next_tmp" "$certs_tmp"
		done < <(printf '%s' "$project_json" | jq -c '.certificates[]')

		tmp="$(mktemp "$target.tmp.XXXXXX")"
		jq -c '{version: 1, certificates: .}' "$certs_tmp" >"$tmp"
		chmod 0600 "$tmp"
		mv -f "$tmp" "$target"
		rm -f "$certs_tmp"
	done < <(jq -c 'to_entries[] | .value + {project: .key}' "$remote_project_delegations_file")

	while IFS= read -r project_json; do
		wait_timeout="$(printf '%s' "$project_json" | jq -r '.waitTimeoutSeconds')"
		remote_project_delegations_wait_for_trust \
			"$wait_timeout" \
			"$(printf '%s' "$project_json" | jq -r '.project')"
	done < <(jq -c 'to_entries[] | select(.value.waitForTrust) | .value + {project: .key}' "$remote_project_delegations_file")
}

instance_is_drained() {
	local id
	id="$1"
	jq -en --argjson ids "$drained_instances" --arg id "$id" '$ids | index($id) != null' >/dev/null
}

reconciler_main() {
	local id name status

	parse_machine_selection_args "$@"

	if ! incus_server_info >/dev/null 2>&1; then
		if [ "$incus_machines_reconcile_mode" = "strict" ]; then
			echo "Incus daemon is unavailable; reconcile cannot continue" >&2
			exit 1
		fi
		echo "Incus daemon is unavailable; skipping best-effort reconcile" >&2
		exit 0
	fi

	while IFS= read -r id; do
		[ -n "$id" ] || continue

		if ! jq -en --argjson ids "$declared_instances" --arg id "$id" '$ids | index($id) != null' >/dev/null; then
			echo "Skipping undeclared Incus instance: $id" >&2
			continue
		fi

		set_current_project_for_instance "$id"
		name="$(instance_name_for_id "$id")"
		status="$(instance_status "$name")"

		if instance_is_drained "$id"; then
			if [ "$status" = "Running" ]; then
				echo "Draining Incus container $current_project/$name"
				if ! systemctl restart "incus-$id.service"; then
					if [ "$incus_machines_reconcile_mode" = "strict" ]; then
						exit 1
					fi
					echo "Best-effort instance drain failed for $id ($current_project/$name); continuing" >&2
				fi
			fi
			continue
		fi

		if [ "$status" = "Running" ]; then
			continue
		fi

		echo "Reconciling Incus instance $current_project/$name (status: $status)"
		if ! systemctl restart "incus-$id.service"; then
			if [ "$incus_machines_reconcile_mode" = "strict" ]; then
				exit 1
			fi
			echo "Best-effort instance reconcile failed for $id ($current_project/$name); continuing" >&2
		fi
	done < <(echo "$selected_json" | jq -r '.[]')
}

settlement_main() {
	local timeout_secs interval_secs deadline pending id name expected_ip expected_ssh_port wait_for_ssh
	local instance_json status instance_state_json
	declare -A network_reconcile_attempted=()

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

		while IFS= read -r id; do
			[ -n "$id" ] || continue

			if ! jq -en --argjson ids "$declared_instances" --arg id "$id" '$ids | index($id) != null' >/dev/null; then
				echo "Skipping undeclared Incus instance: $id" >&2
				continue
			fi

			set_current_project_for_instance "$id"
			name="$(instance_name_for_id "$id")"
			expected_ip="$(
				jq -nr --argjson addresses "${INCUS_MACHINES_INSTANCE_IPV4_ADDRESSES:-"{}"}" --arg id "$id" '$addresses[$id] // ""'
			)"
			expected_ssh_port="$(
				jq -nr --argjson ports "${INCUS_MACHINES_INSTANCE_SSH_PORTS:-"{}"}" --arg id "$id" '$ports[$id] // 22'
			)"
			wait_for_ssh="$(
				jq -nr --argjson wait_for_ssh_by_id "${INCUS_MACHINES_INSTANCE_WAIT_FOR_SSH:-"{}"}" --arg id "$id" '$wait_for_ssh_by_id[$id] // true'
			)"
			instance_json="$(instance_metadata_json "$name")"
			status="$(printf '%s' "$instance_json" | jq -r 'if . == {} then "missing" else .status // "unknown" end')"
			if [ "$status" != "Running" ]; then
				pending=1
				echo "Waiting for Incus instance $current_project/$name to reach Running (current: $status)" >&2
				continue
			fi

			instance_state_json="$(
				incus query "$(query_ref "$(instance_query_path "$name")/state")" --raw 2>/dev/null |
					jq -c '.metadata // {}' 2>/dev/null ||
					echo '{}'
			)"

			if ! instance_accepts_exec "$name"; then
				pending=1
				echo "Waiting for Incus instance $current_project/$name to accept incus exec" >&2
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
				if [ -z "${network_reconcile_attempted[$id]+x}" ]; then
					network_reconcile_attempted[$id]=1
					echo "Reconciling guest network for Incus instance $name" >&2
					instance_reconcile_guest_network "$name" || true
				fi
				pending=1
				echo "Waiting for Incus instance $current_project/$name to report expected IPv4 ${expected_ip}" >&2
				continue
			fi

			if [ "$wait_for_ssh" = "true" ] && [ -n "$expected_ip" ] && ! timeout 5 \
				bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "$expected_ip" "$expected_ssh_port" \
				>/dev/null 2>&1; then
				pending=1
				echo "Waiting for Incus instance $current_project/$name SSH on ${expected_ip}:${expected_ssh_port}" >&2
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

drain_container_instance() {
	local name instance_json instance_type status
	name="$1"
	instance_json="$(incus query "$(query_ref "$(instance_query_path "$name")")" --raw 2>/dev/null || echo '{}')"
	if [ "$instance_json" = "{}" ]; then
		echo "Drain requested for absent Incus container $current_project/$name; suppressing cold-start"
		return 0
	fi
	instance_type="$(printf '%s' "$instance_json" | jq -r '.metadata.type // ""' 2>/dev/null || true)"
	if [ "$instance_type" != "container" ]; then
		echo "Refusing to drain non-container Incus instance $current_project/$name (type: ${instance_type:-unknown})" >&2
		exit 1
	fi
	status="$(printf '%s' "$instance_json" | jq -r '.metadata.status // "unknown"' 2>/dev/null || printf 'unknown\n')"
	if [ "$status" = "Stopped" ]; then
		echo "Incus container $current_project/$name is already drained"
		return 0
	fi
	echo "Stopping Incus container $current_project/$name for migration drain (status: $status)"
	incus_project stop "$(instance_ref "$name")"
}

machine_main() {
	local state_file state_json
	local name instance_name desired_config_hash desired_boot_tag desired_recreate_tag
	local needs_create needs_recreate needs_restart adopting_existing current_config_hash current_recreate_tag current_boot_tag
	local current_instance current_devices current_config current_status desired_disks desired_disk_gc_metadata
	local current_ipv4 current_managed_by current_project desired_props current_props dev dev_exists dev_source dev_pool desired_gc_config_json key props query_name image_tag
	local source_key current_controller
	local instance_image image_alias create_only_devices user_meta_json config_json desired_ipv4 desired_removal_policy desired_adopt desired_drain
	local recovery_attempted start_output
	local -a create_only_device_names current_disk_names desired_disk_names current_prop_keys current_gc_device_names desired_gc_device_names

	state_file="${INCUS_MACHINES_INSTANCE_STATE_FILE?missing INCUS_MACHINES_INSTANCE_STATE_FILE}"
	state_json="$(cat "$state_file")"
	name="$(printf '%s' "$state_json" | jq -r '.name')"
	instance_name="$name"
	current_project="$(printf '%s' "$state_json" | jq -r '.project // "default"')"
	image_tag="$(printf '%s' "$state_json" | jq -r '.imageTag')"
	instance_image="$(printf '%s' "$state_json" | jq -c '.instanceImage')"
	image_alias="$(printf '%s' "$state_json" | jq -r '.imageAlias')"
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
	desired_adopt="$(printf '%s' "$state_json" | jq -r '.adopt // false')"
	desired_drain="$(printf '%s' "$state_json" | jq -r '.drain // false')"
	query_name="$(jq -nr --arg value "$name" '$value | @uri')"
	recovery_attempted=0

	if [ "$desired_drain" = "true" ]; then
		drain_container_instance "$instance_name"
		return 0
	fi

	while :; do
		needs_create=0
		needs_recreate=0
		needs_restart=0
		adopting_existing=0

		if ! incus_project info "$(instance_ref "$instance_name")" >/dev/null 2>&1; then
			needs_create=1
		else
			current_managed_by="$(incus_project config get "$(instance_ref "$instance_name")" user.managed-by 2>/dev/null || true)"
			if [ "$current_managed_by" != "nixos" ]; then
				if [ "$desired_adopt" = "true" ]; then
					echo "Adopting existing Incus instance $current_project/$name"
					adopting_existing=1
				else
					echo "Refusing to manage existing unowned Incus instance $current_project/$name; set adopt = true to adopt it" >&2
					exit 1
				fi
			fi
			current_controller="$(incus_project config get "$(instance_ref "$instance_name")" user.incus-machines.controller 2>/dev/null || true)"
			if [ -n "$controller_id" ] && [ -n "$current_controller" ] && [ "$current_controller" != "$controller_id" ]; then
				echo "Refusing to manage Incus instance $current_project/$name owned by controller $current_controller" >&2
				exit 1
			fi

			current_config_hash="$(incus_project config get "$(instance_ref "$instance_name")" user.config-hash 2>/dev/null || true)"
			current_recreate_tag="$(incus_project config get "$(instance_ref "$instance_name")" user.recreate-tag 2>/dev/null || true)"
			current_boot_tag="$(incus_project config get "$(instance_ref "$instance_name")" user.boot-tag 2>/dev/null || true)"

			if [ "$adopting_existing" -eq 0 ]; then
				if [ "$current_recreate_tag" != "$desired_recreate_tag" ] ||
					{ [ -n "$current_config_hash" ] && [ "$current_config_hash" != "$desired_config_hash" ]; }; then
					needs_recreate=1
				elif [ -n "$current_boot_tag" ] && [ "$current_boot_tag" != "$desired_boot_tag" ]; then
					needs_restart=1
				fi
			fi
		fi

		if [ "$needs_recreate" -eq 1 ]; then
			echo "Recreating $name (config hash or recreate tag changed)..."
			incus_project stop "$(instance_ref "$instance_name")" --force 2>/dev/null || true
			delete_instance_with_recovery "$instance_name"
			needs_create=1
		fi

		if [ "$needs_create" -eq 1 ]; then
			if [ "$instance_image" != "null" ]; then
				ensure_declared_image_present "$instance_image" "$image_tag"
			fi
			echo "Creating $name from image $(target_image_ref "$image_alias")..."
			incus_project create "$(target_image_ref "$image_alias")" "$(instance_ref "$name")"

			if [ "$config_json" != "null" ]; then
				apply_instance_config_json "$instance_name" "$config_json"
			fi

			if [ "$user_meta_json" != "null" ]; then
				apply_instance_config_json "$instance_name" "$user_meta_json"
			fi

			incus_project config device override "$(instance_ref "$instance_name")" eth0 "ipv4.address=$desired_ipv4"

			echo "Adding create-only devices for $name..."
			mapfile -t create_only_device_names < <(json_keys "$create_only_devices")
			if [ "${#create_only_device_names[@]}" -gt 0 ]; then
				for dev in "${create_only_device_names[@]}"; do
					props="$(printf '%s' "$create_only_devices" | jq -c --arg d "$dev" '.[$d]')"
					echo "  Adding device $dev ($(printf '%s' "$props" | jq -r '.type'))"
					add_device_from_props "$instance_name" "$dev" "$props"
				done
			fi
		elif [ "$adopting_existing" -eq 1 ]; then
			if [ "$config_json" != "null" ]; then
				apply_instance_config_json "$instance_name" "$config_json"
			fi

			if [ "$user_meta_json" != "null" ]; then
				apply_instance_config_json "$instance_name" "$user_meta_json"
			fi

			mapfile -t create_only_device_names < <(json_keys "$create_only_devices")
			if [ "${#create_only_device_names[@]}" -gt 0 ]; then
				echo "Adding declared create-only devices while adopting $name..."
				for dev in "${create_only_device_names[@]}"; do
					props="$(printf '%s' "$create_only_devices" | jq -c --arg d "$dev" '.[$d]')"
					echo "  Adding device $dev ($(printf '%s' "$props" | jq -r '.type'))"
					add_device_from_props_idempotent "$instance_name" "$dev" "$props"
				done
			fi
		fi

		current_instance="$(incus query "$(query_ref "/1.0/instances/$query_name")" --raw 2>/dev/null || echo '{}')"
		current_devices="$(printf '%s' "$current_instance" | jq -c '.metadata.devices // {}' 2>/dev/null || echo '{}')"
		current_config="$(printf '%s' "$current_instance" | jq -c '.metadata.config // {}' 2>/dev/null || echo '{}')"

		prepare_certificate_delegation_permissions "$current_config" "$desired_disk_gc_metadata"

		echo "Syncing disk devices for $name..."
		if [ "$adopting_existing" -eq 1 ]; then
			echo "  Skipping undeclared disk removal during first adoption pass"
		else
			mapfile -t current_disk_names < <(
				printf '%s' "$current_devices" |
					jq -r 'to_entries[] | select(.value.type == "disk") | .key' 2>/dev/null ||
					true
			)

			if [ "${#current_disk_names[@]}" -gt 0 ]; then
				for dev in "${current_disk_names[@]}"; do
					if ! printf '%s' "$desired_disks" | jq -e --arg d "$dev" 'has($d)' >/dev/null 2>&1; then
						echo "  Removing disk device $dev"
						incus_project config device remove "$(instance_ref "$instance_name")" "$dev" 2>/dev/null || true
					fi
				done
			fi
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
					if ! incus_project storage volume show "$(storage_pool_ref "$dev_pool")" "$dev_source" >/dev/null 2>&1; then
						echo "  Creating storage volume $dev_pool/$dev_source"
						incus_project storage volume create "$(storage_pool_ref "$dev_pool")" "$dev_source"
					fi
				fi

				if [ "$dev_exists" -eq 0 ]; then
					echo "  Adding disk device $dev"
					add_device_from_props_idempotent "$instance_name" "$dev" "$desired_props"
				fi

				if [ "$dev_exists" -ne 0 ]; then
					mapfile -t current_prop_keys < <(json_property_keys "$current_props")
					if [ "${#current_prop_keys[@]}" -gt 0 ]; then
						for key in "${current_prop_keys[@]}"; do
							if ! printf '%s' "$desired_props" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
								if ! incus_project config device unset "$(instance_ref "$instance_name")" "$dev" "$key"; then
									echo "  Could not unset disk device $dev property $key; continuing" >&2
								fi
							fi
						done
					fi

					set_device_config_json_if_changed "$instance_name" "$dev" "$current_props" "$desired_props"
				fi
			done
		fi

		current_ipv4="$(printf '%s' "$current_devices" | jq -r '.eth0["ipv4.address"] // ""')"
		if [ "$current_ipv4" != "$desired_ipv4" ]; then
			incus_project config device set "$(instance_ref "$instance_name")" eth0 "ipv4.address=$desired_ipv4" 2>/dev/null ||
				incus_project config device override "$(instance_ref "$instance_name")" eth0 "ipv4.address=$desired_ipv4" 2>/dev/null || true
		fi

		set_instance_config_json_if_changed "$instance_name" "$current_config" "$(
			jq -cn \
				--arg configHash "$desired_config_hash" \
				--arg bootTag "$desired_boot_tag" \
				--arg recreateTag "$desired_recreate_tag" \
				--arg removalPolicy "$desired_removal_policy" \
				'{
					"user.config-hash": $configHash,
					"user.boot-tag": $bootTag,
					"user.recreate-tag": $recreateTag,
					"user.removal-policy": $removalPolicy
				}'
		)"

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
			desired_gc_config_json="$(
				printf '%s' "$desired_disk_gc_metadata" |
					jq -c '
						to_entries
						| reduce .[] as $entry ({};
							.["user.device.\($entry.key).removal-policy"] = ($entry.value.removalPolicy // "keep")
							| if (($entry.value.source // "") != "") then
								.["user.device.\($entry.key).source"] = $entry.value.source
							else
								.
							end
						)
					'
			)"
			set_instance_config_json_if_changed "$instance_name" "$current_config" "$desired_gc_config_json"

			for dev in "${desired_gc_device_names[@]}"; do
				source_key="user.device.$dev.source"
				if ! printf '%s' "$desired_gc_config_json" | jq -e --arg key "$source_key" 'has($key)' >/dev/null; then
					unset_instance_config_key_if_present "$instance_name" "$current_config" "$source_key"
				fi
			done
		fi

		if [ "${#current_gc_device_names[@]}" -gt 0 ]; then
			for dev in "${current_gc_device_names[@]}"; do
				if ! printf '%s' "$desired_disks" | jq -e --arg d "$dev" 'has($d)' >/dev/null 2>&1; then
					unset_instance_config_key_if_present "$instance_name" "$current_config" "user.device.$dev.removal-policy"
					unset_instance_config_key_if_present "$instance_name" "$current_config" "user.device.$dev.source"
				fi
			done
		fi

		if [ "$needs_restart" -eq 1 ]; then
			echo "Restarting $name (boot tag changed)..."
			incus_project stop "$(instance_ref "$instance_name")" --force 2>/dev/null || true
		fi

		current_status="$(incus query "$(query_ref "/1.0/instances/$query_name")" --raw 2>/dev/null | jq -r '.metadata.status // "unknown"' 2>/dev/null || printf 'missing\n')"
		if [ "$current_status" != "Running" ]; then
			if ! start_output="$(incus_project start "$(instance_ref "$instance_name")" 2>&1)"; then
				if printf '%s' "$start_output" | grep -qi 'instance is already running'; then
					echo "$name is already running; continuing"
					break
				fi

				printf '%s\n' "$start_output" >&2
				if [ "$recovery_attempted" -eq 0 ] && is_recoverable_start_error "$start_output"; then
					if [ "$adopting_existing" -eq 1 ]; then
						echo "Refusing recovery delete/recreate for adopted existing Incus instance $current_project/$name" >&2
						exit 1
					fi
					echo "Recreating broken $name after failed start..."
					recovery_attempted=1
					incus_project stop "$(instance_ref "$instance_name")" --force 2>/dev/null || true
					delete_instance_with_recovery "$instance_name"
					continue
				fi
				exit 1
			fi
		fi

		current_instance="$(incus query "$(query_ref "/1.0/instances/$query_name")" --raw 2>/dev/null || echo '{}')"
		current_config="$(printf '%s' "$current_instance" | jq -c '.metadata.config // {}' 2>/dev/null || echo '{}')"
		prepare_certificate_delegation_permissions "$current_config" "$desired_disk_gc_metadata"

		break
	done
}

stop_instance_main() {
	local name project
	name="${1?missing instance name}"
	project="${2:-$current_project}"
	current_project="$project"
	incus_project stop "$(instance_ref "$name")" 2>/dev/null || true
}

image_lock_dir_for_key() {
	local key lock_key
	key="$1"
	lock_key="$(
		printf '%s__%s__%s' "${incus_remote_name:-local}" "$current_project" "$key" |
			sha256sum |
			awk '{print $1}'
	)"
	printf '%s/%s\n' "$image_lock_root" "$lock_key"
}

acquire_image_lock() {
	local key lock_dir now lock_mtime
	key="$1"
	lock_dir="$(image_lock_dir_for_key "$key")"
	if ! mkdir -p "$image_lock_root"; then
		echo "Cannot create Incus image lock root $image_lock_root" >&2
		exit 1
	fi
	if [ ! -w "$image_lock_root" ]; then
		echo "Cannot write Incus image lock root $image_lock_root" >&2
		exit 1
	fi
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if [ ! -d "$lock_dir" ]; then
			echo "Cannot create Incus image lock $lock_dir" >&2
			exit 1
		fi
		now="$(date +%s)"
		lock_mtime="$(stat -c %Y "$lock_dir" 2>/dev/null || printf '%s\n' "$now")"
		if [ $((now - lock_mtime)) -gt 600 ]; then
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 1
	done
	printf '%s\n' "$lock_dir"
}

local_image_properties_json() {
	local metadata_file
	metadata_file="$1"

	if ! tar -xOf "$metadata_file" metadata.yaml 2>/dev/null | jq -c '.properties // {}'; then
		echo "Cannot read Incus image metadata properties from $metadata_file" >&2
		exit 1
	fi
}

remote_image_fingerprint() {
	local remote_ref
	remote_ref="$1"

	incus image info "$remote_ref" 2>/dev/null |
		awk -F': *' '$1 == "Fingerprint" { print $2; exit }' ||
		true
}

image_fingerprint_exists() {
	local fingerprint
	fingerprint="$1"

	[ -n "$fingerprint" ] &&
		incus_project image info "$(target_remote_ref)$fingerprint" >/dev/null 2>&1
}

image_fingerprint_for_ref() {
	local image_ref
	image_ref="$1"

	incus_project image info "$image_ref" 2>/dev/null |
		awk -F': *' '$1 == "Fingerprint" { print $2; exit }' ||
		true
}

image_fingerprint_matches_properties() {
	local fingerprint properties_json
	fingerprint="$1"
	properties_json="$2"

	incus_project image list "$(target_remote_ref)" --format=json 2>/dev/null |
		jq -e --arg fingerprint "$fingerprint" --argjson desired "$properties_json" '
			any(.[]; .fingerprint == $fingerprint and (
				. as $image
				| all($desired | keys[]; ($image.properties[.] // "") == ($desired[.] | tostring))
			))
		' >/dev/null
}

image_fingerprint_by_properties() {
	local properties_json
	properties_json="$1"

	incus_project image list "$(target_remote_ref)" --format=json 2>/dev/null |
		jq -r --argjson desired "$properties_json" '
			map(
				. as $image
				| select(all($desired | keys[]; ($image.properties[.] // "") == ($desired[.] | tostring)))
			)
			| first
			| .fingerprint // ""
		' 2>/dev/null ||
		true
}

ensure_image_alias() {
	local alias fingerprint
	alias="$1"
	fingerprint="$2"

	incus_project image alias delete "$(target_image_ref "$alias")" >/dev/null 2>&1 || true
	incus_project image alias create "$(target_image_ref "$alias")" "$fingerprint"
}

ensure_declared_image_present() {
	local image lock_key lock_dir status

	image="$1"
	lock_key="$(printf '%s' "$image" | jq -r '.imageIdentity // .remoteRef // .alias')"
	lock_dir="$(acquire_image_lock "$lock_key")"
	if (
		trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
		ensure_declared_image_present_unlocked "$@"
	); then
		status=0
	else
		status=$?
	fi
	rmdir "$lock_dir" 2>/dev/null || true
	return "$status"
}

ensure_declared_image_present_unlocked() {
	local image desired_rebuild_tag alias image_kind image_identity current_source current_rebuild_tag
	local current_fingerprint desired_fingerprint import_output metadata_file rootfs_file remote_ref existing_fingerprint properties_json

	image="$1"
	desired_rebuild_tag="$2"
	alias="$(printf '%s' "$image" | jq -r '.alias')"
	image_kind="$(printf '%s' "$image" | jq -r '.kind')"
	image_identity="$(printf '%s' "$image" | jq -r '.imageIdentity')"

	current_source="$(incus_project image get-property "$(target_image_ref "$alias")" user.base-image-id 2>/dev/null || true)"
	current_rebuild_tag="$(incus_project image get-property "$(target_image_ref "$alias")" user.base-image-rebuild-tag 2>/dev/null || true)"
	current_fingerprint="$(image_fingerprint_for_ref "$(target_image_ref "$alias")")"

	if [ "$current_source" = "$image_identity" ] &&
		[ "$current_rebuild_tag" = "$desired_rebuild_tag" ] &&
		[ -n "$current_fingerprint" ]; then
		return 0
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

		properties_json="$(local_image_properties_json "$metadata_file")"
		existing_fingerprint="$(
			incus_project image list "$(target_remote_ref)" --format=json 2>/dev/null |
				jq -r --arg image_identity "$image_identity" '
            map(select((.properties["user.base-image-id"] // "") == $image_identity))
            | first
            | .fingerprint // ""
          ' 2>/dev/null ||
				true
		)"

		if [ -n "$current_fingerprint" ] &&
			image_fingerprint_matches_properties "$current_fingerprint" "$properties_json"; then
			:
		elif [ -n "$existing_fingerprint" ]; then
			ensure_image_alias "$alias" "$existing_fingerprint"
		else
			if ! import_output="$(incus_project image import "$metadata_file" "$rootfs_file" "$(target_remote_ref)" --alias "$alias" 2>&1)"; then
				desired_fingerprint="$(image_fingerprint_by_properties "$properties_json")"
				if printf '%s' "$import_output" | grep -qi 'same fingerprint already exists' &&
					[ -n "$desired_fingerprint" ] &&
					ensure_image_alias "$alias" "$desired_fingerprint" >/dev/null 2>&1; then
					:
				else
					printf '%s\n' "$import_output" >&2
					exit 1
				fi
			fi
		fi
		;;
	remote)
		remote_ref="$(printf '%s' "$image" | jq -r '.remoteRef')"
		desired_fingerprint="$(remote_image_fingerprint "$remote_ref")"
		if [ -n "$desired_fingerprint" ] && [ "$current_fingerprint" = "$desired_fingerprint" ]; then
			:
		elif image_fingerprint_exists "$desired_fingerprint"; then
			ensure_image_alias "$alias" "$desired_fingerprint"
		elif ! import_output="$(incus_project image copy "$remote_ref" "$(target_remote_ref)" --alias "$alias" 2>&1)"; then
			if printf '%s' "$import_output" | grep -qi 'same fingerprint already exists' &&
				[ -n "$desired_fingerprint" ] &&
				ensure_image_alias "$alias" "$desired_fingerprint" >/dev/null 2>&1; then
				:
			else
				printf '%s\n' "$import_output" >&2
				exit 1
			fi
		fi
		;;
	*)
		echo "Unknown image kind for $alias: $image_kind" >&2
		exit 1
		;;
	esac

	incus_project image set-property "$(target_image_ref "$alias")" "user.base-image-id=$image_identity"
	incus_project image set-property "$(target_image_ref "$alias")" "user.base-image-rebuild-tag=$desired_rebuild_tag"
}

images_main() {
	local desired_rebuild_tag image

	desired_rebuild_tag="${INCUS_MACHINES_IMAGE_TAG?missing INCUS_MACHINES_IMAGE_TAG}"
	while IFS= read -r image; do
		ensure_declared_image_present "$image" "$desired_rebuild_tag"
	done < <(echo "${INCUS_MACHINES_DECLARED_IMAGES?missing INCUS_MACHINES_DECLARED_IMAGES}" | jq -c '.[]')
}

gc_remote_containers_json() {
	local combined project project_json
	local -a projects

	mapfile -t projects < <(printf '%s' "$gc_projects" | jq -r '.[]' 2>/dev/null || true)
	if [ "${#projects[@]}" -eq 0 ]; then
		projects=("$incus_remote_project")
	fi

	combined='[]'
	for project in "${projects[@]}"; do
		[ -n "$project" ] || continue
		current_project="$project"
		if ! project_json="$(incus_project list "$(server_ref)" --format json 2>/dev/null)"; then
			echo "Failed to list Incus containers for project $project during garbage collection" >&2
			return 1
		fi
		combined="$(
			jq -cn \
				--arg project "$project" \
				--argjson current "$combined" \
				--argjson rows "$project_json" \
				'$current + ($rows | map(.project = (.project // $project)))'
		)"
	done

	printf '%s\n' "$combined"
}

gc_containers_json() {
	if is_remote_target; then
		gc_remote_containers_json
		return
	fi

	incus list --all-projects --format json 2>/dev/null
}

gc_declared_instance_refs_json() {
	local refs_count derived_refs

	refs_count="$(jq -n --argjson refs "$declared_instance_refs" '$refs | length' 2>/dev/null || printf '0\n')"
	if [ "$refs_count" -gt 0 ]; then
		printf '%s\n' "$declared_instance_refs"
		return
	fi

	derived_refs="$(
		jq -cn \
			--argjson ids "$declared_instances" \
			--argjson names "$instance_names" \
			--argjson projects "$instance_projects" '
        reduce ($ids // [])[] as $id ({};
          .[((($projects[$id] // "default") | tostring) + "/" + (($names[$id] // $id) | tostring))] = true
        )
      ' 2>/dev/null || true
	)"

	if [ -n "$derived_refs" ] && [ "$derived_refs" != "null" ]; then
		printf '%s\n' "$derived_refs"
		return
	fi

	printf '{}\n'
}

gc_main() {
	local all_containers cname current_project dir managed owner project removal_policy row effective_declared_instance_refs declared_count effective_refs_count
	local -a dirs_to_remove

	if ! all_containers="$(gc_containers_json)"; then
		echo "Failed to list Incus containers for garbage collection" >&2
		exit 1
	fi
	effective_declared_instance_refs="$(gc_declared_instance_refs_json)"
	declared_count="$(jq -n --argjson ids "$declared_instances" '$ids | length' 2>/dev/null || printf '0\n')"
	effective_refs_count="$(jq -n --argjson refs "$effective_declared_instance_refs" '$refs | length' 2>/dev/null || printf '0\n')"
	if [ "$declared_count" -gt 0 ] &&
		[ "$effective_refs_count" -eq 0 ]; then
		echo "Skipping garbage collection: declared instances are present but project/name refs could not be resolved" >&2
		return 0
	fi

	while IFS= read -r row; do
		cname="$(echo "$row" | jq -r '.name')"
		project="$(echo "$row" | jq -r '.project // "default"')"
		current_project="$project"
		managed="$(echo "$row" | jq -r '.config["user.managed-by"] // ""')"

		[ "$managed" = "nixos" ] || continue
		owner="$(echo "$row" | jq -r '.config["user.incus-machines.controller"] // ""')"
		if [ -n "$controller_id" ] && [ -n "$owner" ] && [ "$owner" != "$controller_id" ]; then
			continue
		fi
		if is_remote_target && [ -n "$controller_id" ] && [ "$owner" != "$controller_id" ]; then
			continue
		fi

		if printf '%s' "$effective_declared_instance_refs" |
			jq -e --arg ref "$project/$cname" '.[$ref] == true' >/dev/null 2>&1; then
			continue
		fi

		removal_policy="$(echo "$row" | jq -r '.config["user.removal-policy"] // "delete-container"')"
		echo "GC: container $project/$cname (policy: $removal_policy)"

		case "$removal_policy" in
		stop-only)
			incus_project stop "$(instance_ref "$cname")" --force 2>/dev/null || true
			;;
		delete-container)
			incus_project delete "$(instance_ref "$cname")" --force 2>/dev/null || true
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

			incus_project delete "$(instance_ref "$cname")" --force 2>/dev/null || true

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
	# Host suspend is local-only by module assertion, and must cover all projects.
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
		echo "usage: incus-machines-helper <preseed-migrations|certificates|certificate-delegation|certificate-delegations-gc|remote-project-delegations|reconciler|settlement|machine|stop-instance|images|gc|host-suspend> [args...]" >&2
		exit 1
	}
	shift

	case "$command" in
	preseed-migrations)
		preseed_migrations_main "$@"
		;;
	certificates)
		certificates_main "$@"
		;;
	certificate-delegation)
		certificate_delegation_main "$@"
		;;
	certificate-delegations-gc)
		certificate_delegations_gc_main "$@"
		;;
	remote-project-delegations)
		remote_project_delegations_main "$@"
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

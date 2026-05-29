#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Entrypoint setup
# -----------------------------------------------------------------------------

init_vars() {
	SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
	SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd -P)"
	COMMON_PATH="${SCRIPT_DIR}/common.sh"
	NIXIFY_SCRIPT="${SCRIPT_DIR}/nixify-vm.sh"
	# shellcheck source=pkgs/ext/gcp-vms/common.sh
	source "${COMMON_PATH}"
	gcp_init_defaults
	gcp_init_vm_config_defaults

	GCP_INSTANCE_NAME=""
	GCP_OUTPUT_JSON="0"
	GCP_CREATE_VM_TMP_DIR=""
	GCP_CREATED_INSTANCE_IP=""
	GCP_CLOUD_INIT_PATH=""
	GCP_NIXIFY_AFTER_CREATE="0"
	GCP_NIXIFY_HOST=""
	GCP_NIXIFY_GENERIC="0"
	GCP_NIXIFY_BUILD_ON_SEEN="0"
	GCP_NIXIFY_NO_DISKO_DEPS="0"
	GCP_NIXIFY_NO_SUBSTITUTE_ON_DESTINATION="0"
	GCP_NIXIFY_ARGS_SEEN="0"
	GCP_NIXIFY_ARGS=()
	GCP_DROP_SSH_FW_AFTER="0"
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
	cat <<'EOF'
Usage:
  pkgs/ext/gcp-vms/create-vm.sh --name <instance> [--project <project>] [--zone <zone>] [options]

Creates an ad hoc Debian VM in GCP, injects a bootstrap SSH key, and waits for
plain SSH access to come up. With --nix, it immediately runs nixify-vm.sh
against the new VM after SSH is reachable.

Required:
  --name <instance>              GCE instance name.

Options:
  --project <project>            GCP project ID. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --zone <zone>                  GCP zone. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --machine-type <type>          Default: configured in pkgs/ext/gcp-vms/common.sh
  --disk-size-gb <gb>            Default: configured in pkgs/ext/gcp-vms/common.sh
  --disk-type <type>             Default: configured in pkgs/ext/gcp-vms/common.sh
  --free-tier-max                Use the current max Compute Engine Free Tier
                                  shape: e2-micro, up to 30GB pd-standard, in a
                                  supported US free-tier region. Explicit
                                  size/zone/image flags must stay eligible.
  --image-family <family>        Default: configured in pkgs/ext/gcp-vms/common.sh
  --image-project <project>      Default: configured in pkgs/ext/gcp-vms/common.sh
  --network <name>               Default: configured in pkgs/ext/gcp-vms/common.sh
  --subnet <name>                Default: configured in pkgs/ext/gcp-vms/common.sh
  --address <addr-or-name>       Optional reserved external address.
  --tags <csv>                   Default: configured in pkgs/ext/gcp-vms/common.sh
  --fw-target-tag <tag>          Default: configured in pkgs/ext/gcp-vms/common.sh
  --ssh-user <user>              Default: configured in pkgs/ext/gcp-vms/common.sh
  --ssh-key <path>               Private key; <path>.pub is injected into GCE.
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --init <path>                  Cloud-init user-data file to pass through GCE
                                  instance metadata.
  --ssh-port <port>              Default: configured in pkgs/ext/gcp-vms/common.sh
  --ssh-wait-timeout <seconds>   Default: configured in pkgs/ext/gcp-vms/common.sh
  --can-ip-forward               Enable GCP instance IP forwarding. Default:
                                  configured in pkgs/ext/gcp-vms/common.sh
  --no-can-ip-forward            Disable GCP instance IP forwarding.
  --ensure-ssh-fw                Create the SSH ingress fw rule when
                                  missing. Requires --network.
  --fw-rule-name <name>          Default: configured in pkgs/ext/gcp-vms/common.sh
  --ssh-source-ranges <csv>      Default: configured in pkgs/ext/gcp-vms/common.sh
  --ensure-observability-fw
                                  Create subnet-scoped observability ingress
                                  for ports configured in pkgs/ext/gcp-vms/common.sh
  --observability-fw-rule-name <name>
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --ensure-postgres-fw           Create subnet-scoped Postgres ingress for
                                  ports configured in pkgs/ext/gcp-vms/common.sh
  --postgres-fw-rule-name <name>
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --ensure-nats-fw               Create subnet-scoped NATS ingress for ports
                                  configured in pkgs/ext/gcp-vms/common.sh
  --nats-fw-rule-name <name>
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --ensure-wireguard-fw          Create public WireGuard ingress and add the
                                  matching allow-wireguard target tag.
  --wireguard-fw-rule-name <name>
  --wireguard-target-tag <tag>
  --wireguard-source-ranges <csv>
  --wireguard-allow <allow-spec>
                                  Defaults configured in pkgs/ext/gcp-vms/common.sh
  --ensure-smtp-fw               Create public SMTP ingress and add the
                                  matching allow-smtp target tag.
  --smtp-fw-rule-name <name>
  --smtp-target-tag <tag>
  --smtp-source-ranges <csv>
  --smtp-allow <allow-spec>
                                  Defaults configured in pkgs/ext/gcp-vms/common.sh
  --ensure-smtps-fw              Create public implicit TLS submission ingress
                                  and add the matching allow-smtps target tag.
  --smtps-fw-rule-name <name>
  --smtps-target-tag <tag>
  --smtps-source-ranges <csv>
  --smtps-allow <allow-spec>
                                  Defaults configured in pkgs/ext/gcp-vms/common.sh
  --ensure-imap-fw               Create public IMAP STARTTLS ingress and add the
                                  matching allow-imap target tag.
  --imap-fw-rule-name <name>
  --imap-target-tag <tag>
  --imap-source-ranges <csv>
  --imap-allow <allow-spec>
                                  Defaults configured in pkgs/ext/gcp-vms/common.sh
  --ensure-imaps-fw               Create public IMAPS ingress and add the
                                  matching allow-imaps target tag.
  --imaps-fw-rule-name <name>
  --imaps-target-tag <tag>
  --imaps-source-ranges <csv>
  --imaps-allow <allow-spec>
                                  Defaults configured in pkgs/ext/gcp-vms/common.sh
  --nix                           Run nixify-vm.sh after VM creation.
  --drop-ssh-fw-after             After successful repo-mode --nix, verify the
                                  configured nixbot deploy route, remove the
                                  SSH target tag from the VM, and delete the
                                  SSH fw rule if unused.
  --host <flake-host>             Nixify repo flake host name. Default: same
                                  as --name.
  --generic                       Nixify into a generated minimal NixOS host.
  --age-identity <path>           Passed to nixify-vm.sh.
  --build-on auto|local|remote    Passed to nixify-vm.sh.
  --post-install-timeout <sec>    Passed to nixify-vm.sh.
  --bootstrap-swap-gb <gb>        Passed to nixify-vm.sh.
  --bootstrap-swap-min-mib <mib>  Passed to nixify-vm.sh.
  --generic-nixpkgs-ref <ref>     Passed to nixify-vm.sh.
  --generic-disk-device <path>    Passed to nixify-vm.sh.
  --force                         Passed to nixify-vm.sh.
  --no-disko-deps                 Passed to nixify-vm.sh.
  --no-substitute-on-destination  Passed to nixify-vm.sh.
  --no-use-machine-substituters   Passed to nixify-vm.sh.
  --print-build-logs              Passed to nixify-vm.sh.
  --debug                         Passed to nixify-vm.sh.
  --copy-host-keys                Passed to nixify-vm.sh.
  --keep-tmp                      Passed to nixify-vm.sh.
  --json                         Emit JSON for machine use.
  -h, --help
EOF
}

ensure_runtime_shell() {
	gcp_ensure_runtime_shell "${SCRIPT_PATH}" "$@"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--name)
			GCP_INSTANCE_NAME="${2:-}"
			shift 2
			;;
		--init)
			gcp_need_value "$1" "${2:-}"
			GCP_CLOUD_INIT_PATH="$2"
			shift 2
			;;
		--project | --zone | --machine-type | --disk-size-gb | --disk-type | --image-family | --image-project | --network | --subnet | --address | --tags | --fw-target-tag | --ssh-user | --ssh-key | --ssh-port | --ssh-wait-timeout | --fw-rule-name | --ssh-source-ranges | --observability-fw-rule-name | --postgres-fw-rule-name | --nats-fw-rule-name | --wireguard-fw-rule-name | --wireguard-target-tag | --wireguard-source-ranges | --wireguard-allow | --smtp-fw-rule-name | --smtp-target-tag | --smtp-source-ranges | --smtp-allow | --smtps-fw-rule-name | --smtps-target-tag | --smtps-source-ranges | --smtps-allow | --imap-fw-rule-name | --imap-target-tag | --imap-source-ranges | --imap-allow | --imaps-fw-rule-name | --imaps-target-tag | --imaps-source-ranges | --imaps-allow)
			gcp_apply_vm_value_arg "$1" "${2:-}"
			shift 2
			;;
		--free-tier-max | --can-ip-forward | --no-can-ip-forward | --ensure-ssh-fw | --ensure-observability-fw | --ensure-postgres-fw | --ensure-nats-fw | --ensure-wireguard-fw | --ensure-smtp-fw | --ensure-smtps-fw | --ensure-imap-fw | --ensure-imaps-fw)
			gcp_apply_vm_flag_arg "$1"
			shift
			;;
		--nix)
			GCP_NIXIFY_AFTER_CREATE="1"
			shift
			;;
		--drop-ssh-fw-after)
			GCP_DROP_SSH_FW_AFTER="1"
			shift
			;;
		--host)
			gcp_need_value "$1" "${2:-}"
			GCP_NIXIFY_HOST="$2"
			GCP_NIXIFY_ARGS_SEEN="1"
			shift 2
			;;
		--age-identity | --build-on | --post-install-timeout | --bootstrap-swap-gb | --bootstrap-swap-min-mib | --generic-nixpkgs-ref | --generic-disk-device)
			gcp_need_value "$1" "${2:-}"
			if [ "$1" = "--build-on" ]; then
				GCP_NIXIFY_BUILD_ON_SEEN="1"
			fi
			GCP_NIXIFY_ARGS+=("$1" "$2")
			GCP_NIXIFY_ARGS_SEEN="1"
			shift 2
			;;
		--generic)
			GCP_NIXIFY_ARGS+=("$1")
			GCP_NIXIFY_GENERIC="1"
			GCP_NIXIFY_ARGS_SEEN="1"
			shift
			;;
		--no-disko-deps)
			GCP_NIXIFY_ARGS+=("$1")
			GCP_NIXIFY_NO_DISKO_DEPS="1"
			GCP_NIXIFY_ARGS_SEEN="1"
			shift
			;;
		--no-substitute-on-destination)
			GCP_NIXIFY_ARGS+=("$1")
			GCP_NIXIFY_NO_SUBSTITUTE_ON_DESTINATION="1"
			GCP_NIXIFY_ARGS_SEEN="1"
			shift
			;;
		--no-use-machine-substituters)
			GCP_NIXIFY_ARGS+=("$1")
			GCP_NIXIFY_ARGS_SEEN="1"
			shift
			;;
		--force | --print-build-logs | --debug | --copy-host-keys | --keep-tmp)
			GCP_NIXIFY_ARGS+=("$1")
			GCP_NIXIFY_ARGS_SEEN="1"
			shift
			;;
		--json)
			GCP_OUTPUT_JSON="1"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage
			gcp_die "Unknown argument: $1"
			;;
		esac
	done
}

validate_args() {
	gcp_finalize_vm_config

	[ -n "${GCP_INSTANCE_NAME}" ] || gcp_die "--name is required"
	[ -n "${GCP_PROJECT_ID}" ] || gcp_die "No GCP project configured; pass --project or set GCP_DEFAULT_PROJECT_ID in pkgs/ext/gcp-vms/common.sh"
	[ -n "${GCP_ZONE}" ] || gcp_die "No GCP zone configured; pass --zone or set GCP_DEFAULT_ZONE in pkgs/ext/gcp-vms/common.sh"
	if [ "${GCP_NIXIFY_AFTER_CREATE}" != "1" ] && [ "${GCP_NIXIFY_ARGS_SEEN}" = "1" ]; then
		gcp_die "Nixify options require --nix"
	fi
	if [ "${GCP_DROP_SSH_FW_AFTER}" = "1" ] && [ "${GCP_NIXIFY_AFTER_CREATE}" != "1" ]; then
		gcp_die "--drop-ssh-fw-after requires --nix"
	fi
	if [ "${GCP_DROP_SSH_FW_AFTER}" = "1" ] && [ "${GCP_NIXIFY_GENERIC}" = "1" ]; then
		gcp_die "--drop-ssh-fw-after requires repo-mode --nix, not --generic"
	fi

	GCP_BOOTSTRAP_SSH_KEY_PATH="$(gcp_expand_path "${GCP_BOOTSTRAP_SSH_KEY_PATH}")"
	[ -f "${GCP_BOOTSTRAP_SSH_KEY_PATH}" ] || gcp_die "SSH private key not found: ${GCP_BOOTSTRAP_SSH_KEY_PATH}"
	[ -f "${GCP_BOOTSTRAP_SSH_KEY_PATH}.pub" ] || gcp_die "SSH public key not found: ${GCP_BOOTSTRAP_SSH_KEY_PATH}.pub"
	if [ -n "${GCP_CLOUD_INIT_PATH}" ]; then
		GCP_CLOUD_INIT_PATH="$(gcp_resolve_repo_path "${GCP_CLOUD_INIT_PATH}")"
		[ -f "${GCP_CLOUD_INIT_PATH}" ] || gcp_die "Cloud-init file not found: ${GCP_CLOUD_INIT_PATH}"
	fi

	if [ "${GCP_NIXIFY_AFTER_CREATE}" = "1" ] && [ "${GCP_NIXIFY_GENERIC}" != "1" ]; then
		preflight_repo_nixify
	fi
}

preflight_repo_nixify() {
	local flake_host="" deploy_user="" _deploy_target="" deploy_key=""
	local bootstrap_key="" age_identity_key="" _proxy_jump=""

	flake_host="${GCP_NIXIFY_HOST:-${GCP_INSTANCE_NAME}}"
	gcp_preflight_flake_host "${flake_host}"
	{
		read -r deploy_user
		read -r _deploy_target
		read -r deploy_key
		read -r bootstrap_key
		read -r age_identity_key
		read -r _proxy_jump
	} < <(gcp_takeover_context "${flake_host}")

	[ -n "${deploy_user}" ] || gcp_die "No deploy user configured for ${flake_host}"
	[ -n "${deploy_key}" ] || gcp_die "No deploy key configured for ${flake_host} in hosts/nixbot.nix"
	[ -n "${bootstrap_key}" ] || gcp_die "No bootstrap key configured for ${flake_host} in hosts/nixbot.nix"
	[ -n "${age_identity_key}" ] || gcp_die "No ageIdentityKey configured for ${flake_host} in hosts/nixbot.nix"
	[ -f "$(gcp_resolve_repo_path "${deploy_key}")" ] || gcp_die "Deploy key secret not found: ${deploy_key}"
	[ -f "$(gcp_resolve_repo_path "${bootstrap_key}")" ] || gcp_die "Bootstrap key secret not found: ${bootstrap_key}"
	[ -f "$(gcp_resolve_repo_path "${age_identity_key}")" ] || gcp_die "Age identity secret not found: ${age_identity_key}"
}

# -----------------------------------------------------------------------------
# Firewall setup
# -----------------------------------------------------------------------------

create_fw_rules() {
	if [ "${GCP_ENSURE_SSH_FW}" = "1" ]; then
		gcp_maybe_create_ssh_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_FW_RULE_NAME}" \
			"${GCP_FW_TARGET_TAG}" \
			"${GCP_SSH_SOURCE_RANGES}"
	fi
	if [ "${GCP_ENSURE_OBSERVABILITY_FW}" = "1" ]; then
		gcp_maybe_create_subnet_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_ZONE}" \
			"${GCP_NETWORK}" \
			"${GCP_SUBNET}" \
			"${GCP_OBSERVABILITY_FW_RULE_NAME}" \
			"${GCP_FW_TARGET_TAG}" \
			"${GCP_OBSERVABILITY_PORTS}"
	fi
	if [ "${GCP_ENSURE_POSTGRES_FW}" = "1" ]; then
		gcp_maybe_create_subnet_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_ZONE}" \
			"${GCP_NETWORK}" \
			"${GCP_SUBNET}" \
			"${GCP_POSTGRES_FW_RULE_NAME}" \
			"${GCP_FW_TARGET_TAG}" \
			"${GCP_POSTGRES_PORTS}"
	fi
	if [ "${GCP_ENSURE_NATS_FW}" = "1" ]; then
		gcp_maybe_create_subnet_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_ZONE}" \
			"${GCP_NETWORK}" \
			"${GCP_SUBNET}" \
			"${GCP_NATS_FW_RULE_NAME}" \
			"${GCP_FW_TARGET_TAG}" \
			"${GCP_NATS_PORTS}"
	fi
	if [ "${GCP_ENSURE_WIREGUARD_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_WIREGUARD_FW_RULE_NAME}" \
			"${GCP_WIREGUARD_TARGET_TAG}" \
			"${GCP_WIREGUARD_SOURCE_RANGES}" \
			"${GCP_WIREGUARD_ALLOW}"
	fi
	if [ "${GCP_ENSURE_SMTP_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_SMTP_FW_RULE_NAME}" \
			"${GCP_SMTP_TARGET_TAG}" \
			"${GCP_SMTP_SOURCE_RANGES}" \
			"${GCP_SMTP_ALLOW}"
	fi
	if [ "${GCP_ENSURE_SMTPS_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_SMTPS_FW_RULE_NAME}" \
			"${GCP_SMTPS_TARGET_TAG}" \
			"${GCP_SMTPS_SOURCE_RANGES}" \
			"${GCP_SMTPS_ALLOW}"
	fi
	if [ "${GCP_ENSURE_IMAP_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_IMAP_FW_RULE_NAME}" \
			"${GCP_IMAP_TARGET_TAG}" \
			"${GCP_IMAP_SOURCE_RANGES}" \
			"${GCP_IMAP_ALLOW}"
	fi
	if [ "${GCP_ENSURE_IMAPS_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_IMAPS_FW_RULE_NAME}" \
			"${GCP_IMAPS_TARGET_TAG}" \
			"${GCP_IMAPS_SOURCE_RANGES}" \
			"${GCP_IMAPS_ALLOW}"
	fi
}

# -----------------------------------------------------------------------------
# VM creation
# -----------------------------------------------------------------------------

create_instance() {
	local metadata_file="" public_key="" instance_ip="" ssh_target=""
	local -a create_cmd=()
	local -a metadata_from_file=()

	GCP_CREATE_VM_TMP_DIR="$(gcp_make_tmp_dir "gcp-create-vm")"
	trap 'gcp_cleanup_tmp_dir "${GCP_CREATE_VM_TMP_DIR:-}"' EXIT

	public_key="$(<"${GCP_BOOTSTRAP_SSH_KEY_PATH}.pub")"
	metadata_file="${GCP_CREATE_VM_TMP_DIR}/ssh-keys"
	printf '%s:%s\n' "${GCP_BOOTSTRAP_SSH_USER}" "${public_key}" >"${metadata_file}"
	metadata_from_file=("ssh-keys=${metadata_file}")
	if [ -n "${GCP_CLOUD_INIT_PATH}" ]; then
		metadata_from_file+=("user-data=${GCP_CLOUD_INIT_PATH}")
	fi
	create_fw_rules

	create_cmd=(
		gcloud compute instances create "${GCP_INSTANCE_NAME}"
		--project "${GCP_PROJECT_ID}"
		--zone "${GCP_ZONE}"
		--machine-type "${GCP_MACHINE_TYPE}"
		--boot-disk-size "${GCP_DISK_SIZE_GB}"
		--boot-disk-type "${GCP_DISK_TYPE}"
		--image-family "${GCP_IMAGE_FAMILY}"
		--image-project "${GCP_IMAGE_PROJECT}"
		--tags "${GCP_TAGS}"
		--metadata enable-oslogin=FALSE
		--metadata-from-file "$(IFS=,; printf '%s' "${metadata_from_file[*]}")"
	)
	if [ "${GCP_CAN_IP_FORWARD}" = "1" ]; then
		create_cmd+=(--can-ip-forward)
	fi

	if [ -n "${GCP_NETWORK}" ]; then
		create_cmd+=(--network "${GCP_NETWORK}")
	fi
	if [ -n "${GCP_SUBNET}" ]; then
		create_cmd+=(--subnet "${GCP_SUBNET}")
	fi
	if [ -n "${GCP_ADDRESS}" ]; then
		create_cmd+=(--address "${GCP_ADDRESS}")
	fi

	gcp_log "Creating GCP instance ${GCP_INSTANCE_NAME}"
	"${create_cmd[@]}" >/dev/null

	instance_ip="$(gcp_instance_ip "${GCP_PROJECT_ID}" "${GCP_ZONE}" "${GCP_INSTANCE_NAME}")"
	[ -n "${instance_ip}" ] || gcp_die "Unable to resolve external IP for ${GCP_INSTANCE_NAME}"

	ssh_target="${GCP_BOOTSTRAP_SSH_USER}@${instance_ip}"
	gcp_log "Waiting for SSH on ${ssh_target}"
	if ! gcp_wait_for_ssh \
		"${ssh_target}" \
		"${GCP_BOOTSTRAP_SSH_KEY_PATH}" \
		"${GCP_BOOTSTRAP_SSH_PORT}" \
		"${GCP_CREATE_VM_TMP_DIR}/known_hosts" \
		"${GCP_SSH_WAIT_TIMEOUT}"; then
		gcp_die "Timed out waiting for SSH on ${ssh_target}"
	fi

	GCP_CREATED_INSTANCE_IP="${instance_ip}"
	if [ "${GCP_NIXIFY_AFTER_CREATE}" = "1" ]; then
		return 0
	fi

	if [ "${GCP_OUTPUT_JSON}" = "1" ]; then
		jq -n \
			--arg name "${GCP_INSTANCE_NAME}" \
			--arg project "${GCP_PROJECT_ID}" \
			--arg zone "${GCP_ZONE}" \
			--arg ip "${instance_ip}" \
			--arg sshUser "${GCP_BOOTSTRAP_SSH_USER}" \
			--arg sshKeyPath "${GCP_BOOTSTRAP_SSH_KEY_PATH}" \
			'{
				name: $name,
				project: $project,
				zone: $zone,
				ip: $ip,
				sshUser: $sshUser,
				sshKeyPath: $sshKeyPath
			}'
	else
		printf 'Instance: %s\nProject: %s\nZone: %s\nIP: %s\nSSH user: %s\nSSH key: %s\n' \
			"${GCP_INSTANCE_NAME}" \
			"${GCP_PROJECT_ID}" \
			"${GCP_ZONE}" \
			"${instance_ip}" \
			"${GCP_BOOTSTRAP_SSH_USER}" \
			"${GCP_BOOTSTRAP_SSH_KEY_PATH}"
	fi
}

# -----------------------------------------------------------------------------
# Optional nixify handoff
# -----------------------------------------------------------------------------

nixify_instance() {
	local -a nixify_cmd=()

	nixify_cmd=(
		"${NIXIFY_SCRIPT}"
		--name "${GCP_INSTANCE_NAME}"
		--project "${GCP_PROJECT_ID}"
		--zone "${GCP_ZONE}"
		--target-host "${GCP_CREATED_INSTANCE_IP}"
		--target-user "${GCP_BOOTSTRAP_SSH_USER}"
		--target-port "${GCP_BOOTSTRAP_SSH_PORT}"
		--ssh-key "${GCP_BOOTSTRAP_SSH_KEY_PATH}"
	)
	if [ -n "${GCP_NIXIFY_HOST}" ]; then
		nixify_cmd+=(--host "${GCP_NIXIFY_HOST}")
	fi
	if [ "${GCP_FREE_TIER_MAX_MODE}" = "1" ]; then
		if [ "${GCP_NIXIFY_BUILD_ON_SEEN}" != "1" ]; then
			nixify_cmd+=(--build-on local)
		fi
		if [ "${GCP_NIXIFY_NO_DISKO_DEPS}" != "1" ]; then
			nixify_cmd+=(--no-disko-deps)
		fi
		if [ "${GCP_NIXIFY_NO_SUBSTITUTE_ON_DESTINATION}" != "1" ]; then
			nixify_cmd+=(--no-substitute-on-destination)
		fi
	fi
	nixify_cmd+=("${GCP_NIXIFY_ARGS[@]}")

	gcp_log "Nixifying VM ${GCP_INSTANCE_NAME}"
	"${nixify_cmd[@]}"
}

# -----------------------------------------------------------------------------
# Optional post-nixify SSH exposure cleanup
# -----------------------------------------------------------------------------

instance_has_tag() {
	local tag="$1"

	gcloud compute instances describe \
		"${GCP_INSTANCE_NAME}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--format=json |
		jq -e --arg tag "${tag}" '
			(.tags.items // []) | index($tag)
		' >/dev/null
}

remove_instance_tag_if_present() {
	local tag="$1"

	[ -n "${tag}" ] || return 0
	if ! instance_has_tag "${tag}"; then
		return 0
	fi

	gcp_log "Removing tag ${tag} from ${GCP_INSTANCE_NAME}"
	gcloud compute instances remove-tags \
		"${GCP_INSTANCE_NAME}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--tags "${tag}" >/dev/null
}

verify_nixbot_deploy_route() {
	local flake_host="$1"

	gcp_log "Verifying nixbot deploy route for ${flake_host}"
	"${REPO_ROOT}/scripts/nixbot.sh" deploy \
		--hosts "${flake_host}" \
		--dry \
		--dirty-staged \
		--log-format plain >/dev/null
}

drop_ssh_fw_after_nix() {
	local flake_host=""

	[ "${GCP_DROP_SSH_FW_AFTER}" = "1" ] || return 0

	flake_host="${GCP_NIXIFY_HOST:-${GCP_INSTANCE_NAME}}"
	verify_nixbot_deploy_route "${flake_host}"
	remove_instance_tag_if_present "${GCP_FW_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_FW_RULE_NAME}" "${GCP_FW_TARGET_TAG}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	init_vars
	ensure_runtime_shell "$@"
	parse_args "$@"
	validate_args
	create_instance
	if [ "${GCP_NIXIFY_AFTER_CREATE}" = "1" ]; then
		nixify_instance
		drop_ssh_fw_after_nix
	fi
}

main "$@"

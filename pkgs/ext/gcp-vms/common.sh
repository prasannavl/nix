#!/usr/bin/env bash
# shellcheck disable=SC2034

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

gcp_init_defaults() {
	gcp_init_base_vm_defaults
	gcp_init_free_tier_defaults
	gcp_init_access_defaults
	gcp_init_firewall_defaults
	gcp_init_nixify_defaults
}

gcp_init_base_vm_defaults() {
	GCP_DEFAULT_PROJECT_ID="${GCP_DEFAULT_PROJECT_ID:-pvl-net}"
	GCP_DEFAULT_REGION="${GCP_DEFAULT_REGION:-asia-southeast1}"
	GCP_DEFAULT_ZONE="${GCP_DEFAULT_ZONE:-${GCP_DEFAULT_REGION}-a}"
	GCP_DEFAULT_NETWORK="${GCP_DEFAULT_NETWORK:-default}"
	GCP_DEFAULT_SUBNET="${GCP_DEFAULT_SUBNET:-default}"
	GCP_DEFAULT_MACHINE_TYPE="${GCP_DEFAULT_MACHINE_TYPE:-n2d-standard-2}"
	GCP_DEFAULT_IMAGE_PROJECT="${GCP_DEFAULT_IMAGE_PROJECT:-debian-cloud}"
	GCP_DEFAULT_IMAGE_FAMILY="${GCP_DEFAULT_IMAGE_FAMILY:-debian-13}"
	GCP_DEFAULT_DISK_TYPE="${GCP_DEFAULT_DISK_TYPE:-pd-ssd}"
	GCP_DEFAULT_DISK_SIZE_GB="${GCP_DEFAULT_DISK_SIZE_GB:-200}"
	GCP_DEFAULT_ADDRESS="${GCP_DEFAULT_ADDRESS:-}"
	GCP_DEFAULT_TAGS="${GCP_DEFAULT_TAGS:-ssh}"
	GCP_DEFAULT_FW_TARGET_TAG="${GCP_DEFAULT_FW_TARGET_TAG:-${GCP_DEFAULT_TAGS%%,*}}"
	GCP_DEFAULT_CAN_IP_FORWARD="${GCP_DEFAULT_CAN_IP_FORWARD:-1}"
}

# -----------------------------------------------------------------------------
# Free Tier preset
# -----------------------------------------------------------------------------

gcp_init_free_tier_defaults() {
	GCP_FREE_TIER_MAX_REGIONS="${GCP_FREE_TIER_MAX_REGIONS:-us-west1,us-central1,us-east1}"
	GCP_FREE_TIER_MAX_REGION="${GCP_FREE_TIER_MAX_REGION:-us-central1}"
	GCP_FREE_TIER_MAX_ZONE="${GCP_FREE_TIER_MAX_ZONE:-${GCP_FREE_TIER_MAX_REGION}-a}"
	GCP_FREE_TIER_MAX_MACHINE_TYPE="${GCP_FREE_TIER_MAX_MACHINE_TYPE:-e2-micro}"
	GCP_FREE_TIER_MAX_IMAGE_PROJECT="${GCP_FREE_TIER_MAX_IMAGE_PROJECT:-debian-cloud}"
	GCP_FREE_TIER_MAX_IMAGE_FAMILY="${GCP_FREE_TIER_MAX_IMAGE_FAMILY:-debian-13}"
	GCP_FREE_TIER_MAX_DISK_TYPE="${GCP_FREE_TIER_MAX_DISK_TYPE:-pd-standard}"
	GCP_FREE_TIER_MAX_DISK_SIZE_GB="${GCP_FREE_TIER_MAX_DISK_SIZE_GB:-30}"
}

gcp_apply_free_tier_max_config() {
	GCP_FREE_TIER_MAX_MODE="1"
}

# -----------------------------------------------------------------------------
# Access and firewall defaults
# -----------------------------------------------------------------------------

gcp_init_access_defaults() {
	GCP_DEFAULT_BOOTSTRAP_SSH_USER="${GCP_DEFAULT_BOOTSTRAP_SSH_USER:-$(id -un)}"
	GCP_DEFAULT_BOOTSTRAP_SSH_KEY_PATH="${GCP_DEFAULT_BOOTSTRAP_SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
	GCP_DEFAULT_BOOTSTRAP_SSH_PORT="${GCP_DEFAULT_BOOTSTRAP_SSH_PORT:-22}"
	GCP_DEFAULT_SSH_WAIT_TIMEOUT="${GCP_DEFAULT_SSH_WAIT_TIMEOUT:-300}"
}

gcp_init_firewall_defaults() {
	GCP_DEFAULT_ENSURE_SSH_FW="${GCP_DEFAULT_ENSURE_SSH_FW:-0}"
	GCP_DEFAULT_FW_RULE_NAME="${GCP_DEFAULT_FW_RULE_NAME:-allow-22}"
	GCP_DEFAULT_SSH_SOURCE_RANGES="${GCP_DEFAULT_SSH_SOURCE_RANGES:-0.0.0.0/0}"
	GCP_DEFAULT_ENSURE_OBSERVABILITY_FW="${GCP_DEFAULT_ENSURE_OBSERVABILITY_FW:-0}"
	GCP_DEFAULT_OBSERVABILITY_FW_RULE_NAME="${GCP_DEFAULT_OBSERVABILITY_FW_RULE_NAME:-allow-observability-subnet}"
	GCP_DEFAULT_OBSERVABILITY_PORTS="${GCP_DEFAULT_OBSERVABILITY_PORTS:-6000,6001,6002}"
	GCP_DEFAULT_ENSURE_POSTGRES_FW="${GCP_DEFAULT_ENSURE_POSTGRES_FW:-0}"
	GCP_DEFAULT_POSTGRES_FW_RULE_NAME="${GCP_DEFAULT_POSTGRES_FW_RULE_NAME:-allow-postgres-subnet}"
	GCP_DEFAULT_POSTGRES_PORTS="${GCP_DEFAULT_POSTGRES_PORTS:-5432}"
	GCP_DEFAULT_ENSURE_NATS_FW="${GCP_DEFAULT_ENSURE_NATS_FW:-0}"
	GCP_DEFAULT_NATS_FW_RULE_NAME="${GCP_DEFAULT_NATS_FW_RULE_NAME:-allow-nats-subnet}"
	GCP_DEFAULT_NATS_PORTS="${GCP_DEFAULT_NATS_PORTS:-4222,7422}"
}

# -----------------------------------------------------------------------------
# Nixify defaults
# -----------------------------------------------------------------------------

gcp_init_nixify_defaults() {
	GCP_DEFAULT_AGE_DECRYPT_IDENTITY_PATH="${GCP_DEFAULT_AGE_DECRYPT_IDENTITY_PATH:-${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}}"
	GCP_DEFAULT_BUILD_ON="${GCP_DEFAULT_BUILD_ON:-auto}"
	GCP_DEFAULT_POST_INSTALL_TIMEOUT="${GCP_DEFAULT_POST_INSTALL_TIMEOUT:-300}"
	GCP_DEFAULT_BOOTSTRAP_SWAP_GB="${GCP_DEFAULT_BOOTSTRAP_SWAP_GB:--1}"
	GCP_DEFAULT_BOOTSTRAP_SWAP_MIN_MIB="${GCP_DEFAULT_BOOTSTRAP_SWAP_MIN_MIB:-4096}"
}

# -----------------------------------------------------------------------------
# Shared VM config expansion
# -----------------------------------------------------------------------------

gcp_init_vm_config_defaults() {
	GCP_PROJECT_ID="${GCP_DEFAULT_PROJECT_ID}"
	GCP_REGION="${GCP_DEFAULT_REGION}"
	GCP_ZONE="${GCP_DEFAULT_ZONE}"
	GCP_MACHINE_TYPE="${GCP_DEFAULT_MACHINE_TYPE}"
	GCP_DISK_SIZE_GB="${GCP_DEFAULT_DISK_SIZE_GB}"
	GCP_DISK_TYPE="${GCP_DEFAULT_DISK_TYPE}"
	GCP_IMAGE_FAMILY="${GCP_DEFAULT_IMAGE_FAMILY}"
	GCP_IMAGE_PROJECT="${GCP_DEFAULT_IMAGE_PROJECT}"
	GCP_NETWORK="${GCP_DEFAULT_NETWORK}"
	GCP_SUBNET="${GCP_DEFAULT_SUBNET}"
	GCP_ADDRESS="${GCP_DEFAULT_ADDRESS}"
	GCP_TAGS="${GCP_DEFAULT_TAGS}"
	GCP_FW_TARGET_TAG="${GCP_DEFAULT_FW_TARGET_TAG}"
	GCP_BOOTSTRAP_SSH_USER="${GCP_DEFAULT_BOOTSTRAP_SSH_USER}"
	GCP_BOOTSTRAP_SSH_KEY_PATH="${GCP_DEFAULT_BOOTSTRAP_SSH_KEY_PATH}"
	GCP_BOOTSTRAP_SSH_PORT="${GCP_DEFAULT_BOOTSTRAP_SSH_PORT}"
	GCP_SSH_WAIT_TIMEOUT="${GCP_DEFAULT_SSH_WAIT_TIMEOUT}"
	GCP_CAN_IP_FORWARD="${GCP_DEFAULT_CAN_IP_FORWARD}"
	GCP_ENSURE_SSH_FW="${GCP_DEFAULT_ENSURE_SSH_FW}"
	GCP_FW_RULE_NAME="${GCP_DEFAULT_FW_RULE_NAME}"
	GCP_SSH_SOURCE_RANGES="${GCP_DEFAULT_SSH_SOURCE_RANGES}"
	GCP_ENSURE_OBSERVABILITY_FW="${GCP_DEFAULT_ENSURE_OBSERVABILITY_FW}"
	GCP_OBSERVABILITY_FW_RULE_NAME="${GCP_DEFAULT_OBSERVABILITY_FW_RULE_NAME}"
	GCP_OBSERVABILITY_PORTS="${GCP_DEFAULT_OBSERVABILITY_PORTS}"
	GCP_ENSURE_POSTGRES_FW="${GCP_DEFAULT_ENSURE_POSTGRES_FW}"
	GCP_POSTGRES_FW_RULE_NAME="${GCP_DEFAULT_POSTGRES_FW_RULE_NAME}"
	GCP_POSTGRES_PORTS="${GCP_DEFAULT_POSTGRES_PORTS}"
	GCP_ENSURE_NATS_FW="${GCP_DEFAULT_ENSURE_NATS_FW}"
	GCP_NATS_FW_RULE_NAME="${GCP_DEFAULT_NATS_FW_RULE_NAME}"
	GCP_NATS_PORTS="${GCP_DEFAULT_NATS_PORTS}"
	GCP_FREE_TIER_MAX_MODE="0"
	GCP_VM_ARG_ZONE_SEEN="0"
	GCP_VM_ARG_MACHINE_TYPE_SEEN="0"
	GCP_VM_ARG_DISK_SIZE_GB_SEEN="0"
	GCP_VM_ARG_DISK_TYPE_SEEN="0"
	GCP_VM_ARG_IMAGE_FAMILY_SEEN="0"
	GCP_VM_ARG_IMAGE_PROJECT_SEEN="0"
}

# -----------------------------------------------------------------------------
# Shared option parsing
# -----------------------------------------------------------------------------

gcp_need_value() {
	local arg="$1" value="${2:-}"

	[ -n "${value}" ] || gcp_die "${arg} requires a value"
}

gcp_apply_vm_value_arg() {
	local arg="$1" value="${2:-}"

	gcp_need_value "${arg}" "${value}"
	case "${arg}" in
	--project) GCP_PROJECT_ID="${value}" ;;
	--zone)
		GCP_ZONE="${value}"
		GCP_REGION="$(gcp_region_from_zone "${value}")"
		GCP_VM_ARG_ZONE_SEEN="1"
		;;
	--machine-type)
		GCP_MACHINE_TYPE="${value}"
		GCP_VM_ARG_MACHINE_TYPE_SEEN="1"
		;;
	--disk-size-gb)
		GCP_DISK_SIZE_GB="${value}"
		GCP_VM_ARG_DISK_SIZE_GB_SEEN="1"
		;;
	--disk-type)
		GCP_DISK_TYPE="${value}"
		GCP_VM_ARG_DISK_TYPE_SEEN="1"
		;;
	--image-family)
		GCP_IMAGE_FAMILY="${value}"
		GCP_VM_ARG_IMAGE_FAMILY_SEEN="1"
		;;
	--image-project)
		GCP_IMAGE_PROJECT="${value}"
		GCP_VM_ARG_IMAGE_PROJECT_SEEN="1"
		;;
	--network) GCP_NETWORK="${value}" ;;
	--subnet) GCP_SUBNET="${value}" ;;
	--address) GCP_ADDRESS="${value}" ;;
	--tags) GCP_TAGS="${value}" ;;
	--fw-target-tag) GCP_FW_TARGET_TAG="${value}" ;;
	--ssh-user) GCP_BOOTSTRAP_SSH_USER="${value}" ;;
	--ssh-key) GCP_BOOTSTRAP_SSH_KEY_PATH="${value}" ;;
	--ssh-port) GCP_BOOTSTRAP_SSH_PORT="${value}" ;;
	--ssh-wait-timeout) GCP_SSH_WAIT_TIMEOUT="${value}" ;;
	--fw-rule-name) GCP_FW_RULE_NAME="${value}" ;;
	--ssh-source-ranges) GCP_SSH_SOURCE_RANGES="${value}" ;;
	--observability-fw-rule-name) GCP_OBSERVABILITY_FW_RULE_NAME="${value}" ;;
	--postgres-fw-rule-name) GCP_POSTGRES_FW_RULE_NAME="${value}" ;;
	--nats-fw-rule-name) GCP_NATS_FW_RULE_NAME="${value}" ;;
	*) return 1 ;;
	esac
}

gcp_apply_vm_flag_arg() {
	local arg="$1"

	case "${arg}" in
	--free-tier-max) gcp_apply_free_tier_max_config ;;
	--can-ip-forward) GCP_CAN_IP_FORWARD="1" ;;
	--no-can-ip-forward) GCP_CAN_IP_FORWARD="0" ;;
	--ensure-ssh-fw) GCP_ENSURE_SSH_FW="1" ;;
	--ensure-observability-fw) GCP_ENSURE_OBSERVABILITY_FW="1" ;;
	--ensure-postgres-fw) GCP_ENSURE_POSTGRES_FW="1" ;;
	--ensure-nats-fw) GCP_ENSURE_NATS_FW="1" ;;
	*) return 1 ;;
	esac
}

gcp_csv_contains() {
	local csv="$1" needle="$2" item=""
	local -a items=()

	IFS=',' read -r -a items <<<"${csv}"
	for item in "${items[@]}"; do
		if [ "${item}" = "${needle}" ]; then
			return 0
		fi
	done

	return 1
}

gcp_positive_int() {
	local value="$1"

	[[ "${value}" =~ ^[1-9][0-9]*$ ]]
}

gcp_apply_free_tier_defaults() {
	if [ "${GCP_VM_ARG_ZONE_SEEN}" != "1" ]; then
		GCP_ZONE="${GCP_FREE_TIER_MAX_ZONE}"
	fi
	GCP_REGION="$(gcp_region_from_zone "${GCP_ZONE}")"
	if [ "${GCP_VM_ARG_MACHINE_TYPE_SEEN}" != "1" ]; then
		GCP_MACHINE_TYPE="${GCP_FREE_TIER_MAX_MACHINE_TYPE}"
	fi
	if [ "${GCP_VM_ARG_IMAGE_PROJECT_SEEN}" != "1" ]; then
		GCP_IMAGE_PROJECT="${GCP_FREE_TIER_MAX_IMAGE_PROJECT}"
	fi
	if [ "${GCP_VM_ARG_IMAGE_FAMILY_SEEN}" != "1" ]; then
		GCP_IMAGE_FAMILY="${GCP_FREE_TIER_MAX_IMAGE_FAMILY}"
	fi
	if [ "${GCP_VM_ARG_DISK_TYPE_SEEN}" != "1" ]; then
		GCP_DISK_TYPE="${GCP_FREE_TIER_MAX_DISK_TYPE}"
	fi
	if [ "${GCP_VM_ARG_DISK_SIZE_GB_SEEN}" != "1" ]; then
		GCP_DISK_SIZE_GB="${GCP_FREE_TIER_MAX_DISK_SIZE_GB}"
	fi
}

gcp_validate_free_tier_max_config() {
	local zone_region=""

	zone_region="$(gcp_region_from_zone "${GCP_ZONE}")"
	if ! gcp_csv_contains "${GCP_FREE_TIER_MAX_REGIONS}" "${zone_region}"; then
		gcp_die "--free-tier-max requires a zone in one of: ${GCP_FREE_TIER_MAX_REGIONS}; got ${GCP_ZONE}"
	fi
	[ "${GCP_MACHINE_TYPE}" = "${GCP_FREE_TIER_MAX_MACHINE_TYPE}" ] ||
		gcp_die "--free-tier-max requires --machine-type ${GCP_FREE_TIER_MAX_MACHINE_TYPE}; got ${GCP_MACHINE_TYPE}"
	[ "${GCP_IMAGE_PROJECT}" = "${GCP_FREE_TIER_MAX_IMAGE_PROJECT}" ] ||
		gcp_die "--free-tier-max requires --image-project ${GCP_FREE_TIER_MAX_IMAGE_PROJECT}; got ${GCP_IMAGE_PROJECT}"
	[ "${GCP_IMAGE_FAMILY}" = "${GCP_FREE_TIER_MAX_IMAGE_FAMILY}" ] ||
		gcp_die "--free-tier-max requires --image-family ${GCP_FREE_TIER_MAX_IMAGE_FAMILY}; got ${GCP_IMAGE_FAMILY}"
	[ "${GCP_DISK_TYPE}" = "${GCP_FREE_TIER_MAX_DISK_TYPE}" ] ||
		gcp_die "--free-tier-max requires --disk-type ${GCP_FREE_TIER_MAX_DISK_TYPE}; got ${GCP_DISK_TYPE}"
	gcp_positive_int "${GCP_DISK_SIZE_GB}" ||
		gcp_die "--free-tier-max requires a positive integer --disk-size-gb; got ${GCP_DISK_SIZE_GB}"
	[ "${GCP_DISK_SIZE_GB}" -le "${GCP_FREE_TIER_MAX_DISK_SIZE_GB}" ] ||
		gcp_die "--free-tier-max allows at most ${GCP_FREE_TIER_MAX_DISK_SIZE_GB}GB ${GCP_FREE_TIER_MAX_DISK_TYPE}; got ${GCP_DISK_SIZE_GB}GB"
}

gcp_finalize_vm_config() {
	if [ "${GCP_FREE_TIER_MAX_MODE}" = "1" ]; then
		gcp_apply_free_tier_defaults
		gcp_validate_free_tier_max_config
	else
		GCP_REGION="$(gcp_region_from_zone "${GCP_ZONE}")"
	fi
}

# -----------------------------------------------------------------------------
# Runtime shell
# -----------------------------------------------------------------------------

gcp_runtime_shell_expr() {
	cat <<'EOF'
with import <nixpkgs> {};
buildEnv {
  name = "gcp-vms-runtime";
  paths = [
    age
    gitMinimal
    jq
    nix
    nixos-anywhere
    openssl
    openssh
    google-cloud-sdk
  ];
}
EOF
}

gcp_ensure_runtime_shell() {
	local script_path="$1"
	shift

	if [ "${GCP_VMS_IN_NIX_SHELL:-0}" = "1" ]; then
		return
	fi

	command -v nix >/dev/null 2>&1 || gcp_die "Required command not found: nix"
	exec nix shell --impure --expr "$(gcp_runtime_shell_expr)" -c \
		env GCP_VMS_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

# -----------------------------------------------------------------------------
# Basic utilities
# -----------------------------------------------------------------------------

gcp_die() {
	printf '%s\n' "$*" >&2
	exit 1
}

gcp_log() {
	printf '==> %s\n' "$*" >&2
}

gcp_expand_path() {
	local path="$1"

	case "${path}" in
	~) printf '%s\n' "${HOME}" ;;
	~/*) printf '%s/%s\n' "${HOME}" "${path#~/}" ;;
	*) printf '%s\n' "${path}" ;;
	esac
}

gcp_resolve_repo_path() {
	local path="$1"

	if [[ "${path}" = /* ]]; then
		printf '%s\n' "${path}"
		return
	fi

	if [ -e "${path}" ]; then
		printf '%s\n' "${path}"
		return
	fi

	printf '%s/%s\n' "${REPO_ROOT}" "${path}"
}

gcp_ensure_tmp_root() {
	mkdir -p "${REPO_ROOT}/tmp"
}

gcp_make_tmp_dir() {
	local prefix="$1"

	gcp_ensure_tmp_root
	mktemp -d "${REPO_ROOT}/tmp/${prefix}.XXXXXX"
}

gcp_cleanup_tmp_dir() {
	local dir="${1:-}"

	[ -n "${dir}" ] || return 0
	[ -d "${dir}" ] || return 0
	rm -rf -- "${dir}"
}

# -----------------------------------------------------------------------------
# SSH helpers
# -----------------------------------------------------------------------------

gcp_ssh_ready() {
	local ssh_target="$1" ssh_key_path="$2" ssh_port="$3" known_hosts_file="$4"
	shift 4
	local -a extra_opts=("$@")

	ssh \
		-i "${ssh_key_path}" \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		-o StrictHostKeyChecking=accept-new \
		-o "UserKnownHostsFile=${known_hosts_file}" \
		-p "${ssh_port}" \
		"${extra_opts[@]}" \
		"${ssh_target}" \
		true >/dev/null 2>&1
}

gcp_wait_for_ssh() {
	local ssh_target="$1" ssh_key_path="$2" ssh_port="$3" known_hosts_file="$4" timeout_seconds="$5"
	shift 5
	local -a extra_opts=("$@")
	local deadline=""

	deadline=$((SECONDS + timeout_seconds))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if gcp_ssh_ready \
			"${ssh_target}" \
			"${ssh_key_path}" \
			"${ssh_port}" \
			"${known_hosts_file}" \
			"${extra_opts[@]}"; then
			return 0
		fi
		sleep 5
	done

	return 1
}

# -----------------------------------------------------------------------------
# Repo-defined NixOS takeover helpers
# -----------------------------------------------------------------------------

gcp_preflight_flake_host() {
	local flake_host="$1"

	gcp_log "Evaluating .#nixosConfigurations.${flake_host}"
	nix build \
		--dry-run \
		--no-link \
		".#nixosConfigurations.${flake_host}.config.system.build.toplevel" >/dev/null
}

gcp_load_nixbot_config_json() {
	nix eval --json --file "${REPO_ROOT}/hosts/nixbot.nix"
}

gcp_takeover_context() {
	local flake_host="$1"
	local config_json="" context_json=""

	config_json="$(gcp_load_nixbot_config_json)"
	context_json="$(
		jq -cer --arg host "${flake_host}" '
			. as $root
			| ($root.defaults // {}) as $defs
			| ($root.hosts[$host] // error("missing host in hosts/nixbot.nix: " + $host)) as $cfg
			| def fb($v; $d): ($v // "") | if . == "" then $d else . end;
			{
				deployUser: fb($cfg.user; ($defs.user // "nixbot")),
				deployTarget: fb($cfg.target; $host),
				deployKey: fb($cfg.key; ($defs.key // "")),
				bootstrapKey: fb($cfg.bootstrapKey; (fb($cfg.key; ($defs.bootstrapKey // $defs.key // "")))),
				ageIdentityKey: fb($cfg.ageIdentityKey; ($defs.ageIdentityKey // "")),
				proxyJump: ($cfg.proxyJump // "")
			}
		' <<<"${config_json}"
	)" || return 1

	jq -r '.deployUser, .deployTarget, .deployKey, .bootstrapKey, .ageIdentityKey, .proxyJump' <<<"${context_json}"
}

gcp_decrypt_secret_to_path() {
	local src_path="$1" dest_path="$2" decrypt_identity_path="$3"

	if [[ "${src_path}" = *.age ]]; then
		[ -f "${decrypt_identity_path}" ] || gcp_die "Age identity file not found: ${decrypt_identity_path}"
		age --decrypt -i "${decrypt_identity_path}" -o "${dest_path}" "${src_path}"
	else
		cp "${src_path}" "${dest_path}"
	fi

	chmod 600 "${dest_path}"
}

gcp_stage_takeover_files() {
	local bootstrap_key_secret="$1" age_identity_secret="$2" decrypt_identity_path="$3" stage_root="$4"

	mkdir -p "${stage_root}/var/lib/nixbot/.ssh" "${stage_root}/var/lib/nixbot/.age"
	chmod 700 "${stage_root}/var/lib/nixbot/.ssh" "${stage_root}/var/lib/nixbot/.age"

	gcp_decrypt_secret_to_path \
		"${bootstrap_key_secret}" \
		"${stage_root}/var/lib/nixbot/.ssh/id_ed25519" \
		"${decrypt_identity_path}"
	gcp_decrypt_secret_to_path \
		"${age_identity_secret}" \
		"${stage_root}/var/lib/nixbot/.age/identity" \
		"${decrypt_identity_path}"
}

# -----------------------------------------------------------------------------
# GCP lookup helpers
# -----------------------------------------------------------------------------

gcp_instance_ip() {
	local project_id="$1" zone="$2" instance_name="$3"

	gcloud compute instances describe \
		"${instance_name}" \
		--project "${project_id}" \
		--zone "${zone}" \
		--format='value(networkInterfaces[0].accessConfigs[0].natIP)'
}

gcp_discover_instance_zone() {
	local project_id="$1" instance_name="$2"
	local zones="" zone_count=""

	zones="$(
		gcloud compute instances list \
			--project "${project_id}" \
			--filter "name=${instance_name}" \
			--format='value(zone)' 2>/dev/null || true
	)"
	zone_count="$(grep -c . <<<"${zones}" || true)"
	if [ "${zone_count}" -gt 1 ]; then
		gcp_die "Multiple instances named ${instance_name} found in ${project_id}; pass --zone"
	fi

	printf '%s\n' "${zones}"
}

gcp_region_from_zone() {
	local zone="$1"

	printf '%s\n' "${zone%-*}"
}

gcp_subnet_cidr() {
	local project_id="$1" zone="$2" subnet="$3"
	local region=""

	region="$(gcp_region_from_zone "${zone}")"
	gcloud compute networks subnets describe \
		"${subnet}" \
		--project "${project_id}" \
		--region "${region}" \
		--format='value(ipCidrRange)'
}

# -----------------------------------------------------------------------------
# Firewall helpers
# -----------------------------------------------------------------------------

gcp_maybe_create_fw_rule() {
	local project_id="$1" network="$2" fw_rule_name="$3" target_tag="$4"
	local source_ranges="$5" allow_spec="$6"

	[ -n "${network}" ] || gcp_die "Fw rule ${fw_rule_name} requires --network"
	[ -n "${target_tag}" ] || gcp_die "Fw rule ${fw_rule_name} requires a target tag"
	[ -n "${source_ranges}" ] || gcp_die "Fw rule ${fw_rule_name} requires source ranges"
	[ -n "${allow_spec}" ] || gcp_die "Fw rule ${fw_rule_name} requires allow spec"

	if gcloud compute firewall-rules describe \
		"${fw_rule_name}" \
		--project "${project_id}" >/dev/null 2>&1; then
		gcp_log "Reusing fw rule ${fw_rule_name}"
		return 0
	fi

	gcp_log "Creating fw rule ${fw_rule_name}"
	gcloud compute firewall-rules create \
		"${fw_rule_name}" \
		--project "${project_id}" \
		--network "${network}" \
		--allow "${allow_spec}" \
		--source-ranges "${source_ranges}" \
		--target-tags "${target_tag}" >/dev/null
}

gcp_maybe_create_ssh_fw() {
	local project_id="$1" network="$2" fw_rule_name="$3" ssh_tag="$4" source_ranges="$5"

	gcp_maybe_create_fw_rule \
		"${project_id}" \
		"${network}" \
		"${fw_rule_name}" \
		"${ssh_tag}" \
		"${source_ranges}" \
		"tcp:22"
}

gcp_maybe_create_subnet_fw() {
	local project_id="$1" zone="$2" network="$3" subnet="$4" fw_rule_name="$5"
	local target_tag="$6" ports_csv="$7" cidr=""

	[ -n "${subnet}" ] || gcp_die "Fw rule ${fw_rule_name} requires --subnet"
	cidr="$(gcp_subnet_cidr "${project_id}" "${zone}" "${subnet}")"
	[ -n "${cidr}" ] || gcp_die "Unable to resolve subnet CIDR for ${subnet} in ${zone}"

	gcp_maybe_create_fw_rule \
		"${project_id}" \
		"${network}" \
		"${fw_rule_name}" \
		"${target_tag}" \
		"${cidr}" \
		"tcp:${ports_csv}"
}

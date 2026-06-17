#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Entrypoint setup
# -----------------------------------------------------------------------------

init_vars() {
	SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
	SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd -P)"
	# shellcheck disable=SC2034
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd -P)"
	COMMON_PATH="${SCRIPT_DIR}/common.sh"
	# shellcheck source=pkgs/ext/gcp-vms/common.sh
	source "${COMMON_PATH}"
	gcp_init_defaults
	gcp_init_vm_config_defaults

	GCP_INSTANCE_NAME=""
	GCP_INSTANCE_ZONE_ARG_SEEN="0"
	GCP_IAP_SSH_USER="$(id -un)"
	GCP_IAP_SSH_KEY_PATH="${GCP_BOOTSTRAP_SSH_KEY_PATH}"
	GCP_IAP_SSH_RULE_NAME="allow-iap-ssh"
	GCP_IAP_SSH_TARGET_TAG="allow-iap-ssh"
	GCP_IAP_SSH_SOURCE_RANGES="35.235.240.0/20"
	GCP_IAP_CLEANUP="1"
	GCP_IAP_CLEANUP_ONLY="0"
	GCP_IAP_EXTRA_ARGS=()
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
	cat <<'EOF'
Usage:
  pkgs/ext/gcp-vms/iap-ssh.sh --name <instance> [--project <project>] [options] [-- <gcloud ssh args...>]

Temporarily enables IAP SSH to a GCE instance, runs gcloud compute ssh with
--tunnel-through-iap, then removes the temporary tag and deletes the firewall
rule if no other instance still uses it.

Options:
  --name <instance>              GCE instance name.
  --project <project>            GCP project ID. Default: configured in common.sh.
  --zone <zone>                  Optional GCP zone. Required unless the instance
                                  name is unique in the project.
  --network <name>               Default: configured in common.sh.
  --ssh-user <user>              SSH user for gcloud compute ssh. Default: current user.
  --ssh-key <path>               SSH private key. Default: common.sh bootstrap key.
  --iap-ssh-fw-rule-name <name>  Default: allow-iap-ssh.
  --iap-ssh-target-tag <tag>     Default: allow-iap-ssh.
  --iap-ssh-source-ranges <csv>  Default: 35.235.240.0/20.
  --keep-access                  Do not remove the tag/firewall after SSH exits.
  --cleanup-only                 Remove the temporary tag/firewall without SSH.
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
			gcp_need_value "$1" "${2:-}"
			GCP_INSTANCE_NAME="${2:-}"
			shift 2
			;;
		--zone)
			gcp_apply_vm_value_arg "$1" "${2:-}"
			GCP_INSTANCE_ZONE_ARG_SEEN="1"
			shift 2
			;;
		--project | --network)
			gcp_apply_vm_value_arg "$1" "${2:-}"
			shift 2
			;;
		--ssh-user)
			gcp_need_value "$1" "${2:-}"
			GCP_IAP_SSH_USER="${2:-}"
			shift 2
			;;
		--ssh-key)
			gcp_need_value "$1" "${2:-}"
			GCP_IAP_SSH_KEY_PATH="$(gcp_expand_path "${2:-}")"
			shift 2
			;;
		--iap-ssh-fw-rule-name)
			gcp_need_value "$1" "${2:-}"
			GCP_IAP_SSH_RULE_NAME="${2:-}"
			shift 2
			;;
		--iap-ssh-target-tag)
			gcp_need_value "$1" "${2:-}"
			GCP_IAP_SSH_TARGET_TAG="${2:-}"
			shift 2
			;;
		--iap-ssh-source-ranges)
			gcp_need_value "$1" "${2:-}"
			GCP_IAP_SSH_SOURCE_RANGES="${2:-}"
			shift 2
			;;
		--keep-access)
			GCP_IAP_CLEANUP="0"
			shift
			;;
		--cleanup-only)
			GCP_IAP_CLEANUP_ONLY="1"
			shift
			;;
		--)
			shift
			GCP_IAP_EXTRA_ARGS=("$@")
			break
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
	[ -n "${GCP_INSTANCE_NAME}" ] || gcp_die "--name is required"
	[ -n "${GCP_PROJECT_ID}" ] || gcp_die "No GCP project configured; pass --project or set GCP_DEFAULT_PROJECT_ID in common.sh"
	[ -n "${GCP_NETWORK}" ] || gcp_die "No GCP network configured; pass --network or set GCP_DEFAULT_NETWORK in common.sh"
	[ -n "${GCP_IAP_SSH_USER}" ] || gcp_die "--ssh-user cannot be empty"
	[ -n "${GCP_IAP_SSH_KEY_PATH}" ] || gcp_die "--ssh-key cannot be empty"
	[ -f "${GCP_IAP_SSH_KEY_PATH}" ] || gcp_die "SSH key not found: ${GCP_IAP_SSH_KEY_PATH}"
	[ -n "${GCP_IAP_SSH_RULE_NAME}" ] || gcp_die "--iap-ssh-fw-rule-name cannot be empty"
	[ -n "${GCP_IAP_SSH_TARGET_TAG}" ] || gcp_die "--iap-ssh-target-tag cannot be empty"
	[ -n "${GCP_IAP_SSH_SOURCE_RANGES}" ] || gcp_die "--iap-ssh-source-ranges cannot be empty"

	if [ "${GCP_INSTANCE_ZONE_ARG_SEEN}" != "1" ]; then
		GCP_ZONE="$(gcp_discover_instance_zone "${GCP_PROJECT_ID}" "${GCP_INSTANCE_NAME}")"
	fi
	[ -n "${GCP_ZONE}" ] || gcp_die "Unable to discover zone for ${GCP_INSTANCE_NAME}; pass --zone"
}

# -----------------------------------------------------------------------------
# IAP access
# -----------------------------------------------------------------------------

ensure_iap_access() {
	gcp_maybe_create_ssh_fw \
		"${GCP_PROJECT_ID}" \
		"${GCP_NETWORK}" \
		"${GCP_IAP_SSH_RULE_NAME}" \
		"${GCP_IAP_SSH_TARGET_TAG}" \
		"${GCP_IAP_SSH_SOURCE_RANGES}"
	gcp_add_instance_tag_if_missing \
		"${GCP_PROJECT_ID}" \
		"${GCP_ZONE}" \
		"${GCP_INSTANCE_NAME}" \
		"${GCP_IAP_SSH_TARGET_TAG}"
}

cleanup_iap_access() {
	[ "${GCP_IAP_CLEANUP}" = "1" ] || return 0

	gcp_log "Removing tag ${GCP_IAP_SSH_TARGET_TAG} from ${GCP_INSTANCE_NAME}"
	gcloud compute instances remove-tags \
		"${GCP_INSTANCE_NAME}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--tags "${GCP_IAP_SSH_TARGET_TAG}" >/dev/null 2>&1 || true

	gcp_delete_fw_rule_if_unused \
		"${GCP_PROJECT_ID}" \
		"${GCP_IAP_SSH_RULE_NAME}" \
		"${GCP_IAP_SSH_TARGET_TAG}"
}

run_iap_ssh() {
	gcloud compute ssh \
		"${GCP_IAP_SSH_USER}@${GCP_INSTANCE_NAME}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--tunnel-through-iap \
		--ssh-key-file "${GCP_IAP_SSH_KEY_PATH}" \
		--ssh-flag=-F \
		--ssh-flag=/dev/null \
		"${GCP_IAP_EXTRA_ARGS[@]}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	init_vars
	ensure_runtime_shell "$@"
	parse_args "$@"
	validate_args

	if [ "${GCP_IAP_CLEANUP_ONLY}" = "1" ]; then
		cleanup_iap_access
		return 0
	fi

	ensure_iap_access
	trap cleanup_iap_access EXIT
	run_iap_ssh
}

main "$@"

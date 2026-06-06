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
	# shellcheck source=pkgs/ext/gcp-vms/common.sh
	source "${COMMON_PATH}"
	gcp_init_defaults
	gcp_init_vm_config_defaults

	GCP_INSTANCE_NAME=""
	GCP_INSTANCE_ZONE_ARG_SEEN="0"
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
	cat <<'EOF'
Usage:
  pkgs/ext/gcp-vms/ensure-firewall.sh [--name <instance>] [--project <project>] [options]

Ensures reusable GCP firewall rules from pkgs/ext/gcp-vms/common.sh exist. When
--name is supplied, matching target tags are added to the existing instance.

Options:
  --name <instance>              Optional GCE instance name to tag.
  --project <project>            GCP project ID. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --zone <zone>                  Optional GCP zone. Required with --name unless
                                  the instance name is unique in the project.
  --network <name>               Default: configured in pkgs/ext/gcp-vms/common.sh
  --subnet <name>                Default: configured in pkgs/ext/gcp-vms/common.sh
  --fw-target-tag <tag>          Default target tag for subnet-scoped rules.
  --ensure-ssh-fw
  --fw-rule-name <name>
  --ssh-source-ranges <csv>
  --ensure-observability-fw
  --observability-fw-rule-name <name>
  --ensure-postgres-fw
  --postgres-fw-rule-name <name>
  --ensure-nats-fw
  --nats-fw-rule-name <name>
  --ensure-wireguard-fw
  --wireguard-fw-rule-name <name>
  --wireguard-target-tag <tag>
  --wireguard-source-ranges <csv>
  --wireguard-allow <allow-spec>
  --ensure-smtp-fw
  --smtp-fw-rule-name <name>
  --smtp-target-tag <tag>
  --smtp-source-ranges <csv>
  --smtp-allow <allow-spec>
  --ensure-smtps-fw
  --smtps-fw-rule-name <name>
  --smtps-target-tag <tag>
  --smtps-source-ranges <csv>
  --smtps-allow <allow-spec>
  --ensure-imap-fw
  --imap-fw-rule-name <name>
  --imap-target-tag <tag>
  --imap-source-ranges <csv>
  --imap-allow <allow-spec>
  --ensure-imaps-fw
  --imaps-fw-rule-name <name>
  --imaps-target-tag <tag>
  --imaps-source-ranges <csv>
  --imaps-allow <allow-spec>
  --ensure-https-fw
  --https-fw-rule-name <name>
  --https-target-tag <tag>
  --https-source-ranges <csv>
  --https-allow <allow-spec>
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
		--project | --network | --subnet | --fw-target-tag | --fw-rule-name | --ssh-source-ranges | --observability-fw-rule-name | --postgres-fw-rule-name | --nats-fw-rule-name | --wireguard-fw-rule-name | --wireguard-target-tag | --wireguard-source-ranges | --wireguard-allow | --smtp-fw-rule-name | --smtp-target-tag | --smtp-source-ranges | --smtp-allow | --smtps-fw-rule-name | --smtps-target-tag | --smtps-source-ranges | --smtps-allow | --imap-fw-rule-name | --imap-target-tag | --imap-source-ranges | --imap-allow | --imaps-fw-rule-name | --imaps-target-tag | --imaps-source-ranges | --imaps-allow | --https-fw-rule-name | --https-target-tag | --https-source-ranges | --https-allow)
			gcp_apply_vm_value_arg "$1" "${2:-}"
			shift 2
			;;
		--ensure-ssh-fw | --ensure-observability-fw | --ensure-postgres-fw | --ensure-nats-fw | --ensure-wireguard-fw | --ensure-smtp-fw | --ensure-smtps-fw | --ensure-imap-fw | --ensure-imaps-fw | --ensure-https-fw)
			gcp_apply_vm_flag_arg "$1"
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
	[ -n "${GCP_PROJECT_ID}" ] || gcp_die "No GCP project configured; pass --project or set GCP_DEFAULT_PROJECT_ID in pkgs/ext/gcp-vms/common.sh"
	[ -n "${GCP_NETWORK}" ] || gcp_die "No GCP network configured; pass --network or set GCP_DEFAULT_NETWORK in pkgs/ext/gcp-vms/common.sh"
	if [ -n "${GCP_INSTANCE_NAME}" ] && [ "${GCP_INSTANCE_ZONE_ARG_SEEN}" != "1" ]; then
		GCP_ZONE="$(gcp_discover_instance_zone "${GCP_PROJECT_ID}" "${GCP_INSTANCE_NAME}")"
	fi
	if [ -n "${GCP_INSTANCE_NAME}" ]; then
		[ -n "${GCP_ZONE}" ] || gcp_die "Unable to discover zone for ${GCP_INSTANCE_NAME}; pass --zone"
	fi
}

# -----------------------------------------------------------------------------
# Firewall setup
# -----------------------------------------------------------------------------

maybe_tag_instance() {
	local target_tag="$1"

	[ -n "${GCP_INSTANCE_NAME}" ] || return 0
	gcp_add_instance_tag_if_missing \
		"${GCP_PROJECT_ID}" \
		"${GCP_ZONE}" \
		"${GCP_INSTANCE_NAME}" \
		"${target_tag}"
}

ensure_fw_rules() {
	if [ "${GCP_ENSURE_SSH_FW}" = "1" ]; then
		gcp_maybe_create_ssh_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_FW_RULE_NAME}" \
			"${GCP_FW_TARGET_TAG}" \
			"${GCP_SSH_SOURCE_RANGES}"
		maybe_tag_instance "${GCP_FW_TARGET_TAG}"
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
		maybe_tag_instance "${GCP_FW_TARGET_TAG}"
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
		maybe_tag_instance "${GCP_FW_TARGET_TAG}"
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
		maybe_tag_instance "${GCP_FW_TARGET_TAG}"
	fi
	if [ "${GCP_ENSURE_WIREGUARD_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_WIREGUARD_FW_RULE_NAME}" \
			"${GCP_WIREGUARD_TARGET_TAG}" \
			"${GCP_WIREGUARD_SOURCE_RANGES}" \
			"${GCP_WIREGUARD_ALLOW}"
		maybe_tag_instance "${GCP_WIREGUARD_TARGET_TAG}"
	fi
	if [ "${GCP_ENSURE_SMTP_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_SMTP_FW_RULE_NAME}" \
			"${GCP_SMTP_TARGET_TAG}" \
			"${GCP_SMTP_SOURCE_RANGES}" \
			"${GCP_SMTP_ALLOW}"
		maybe_tag_instance "${GCP_SMTP_TARGET_TAG}"
	fi
	if [ "${GCP_ENSURE_SMTPS_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_SMTPS_FW_RULE_NAME}" \
			"${GCP_SMTPS_TARGET_TAG}" \
			"${GCP_SMTPS_SOURCE_RANGES}" \
			"${GCP_SMTPS_ALLOW}"
		maybe_tag_instance "${GCP_SMTPS_TARGET_TAG}"
	fi
	if [ "${GCP_ENSURE_IMAP_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_IMAP_FW_RULE_NAME}" \
			"${GCP_IMAP_TARGET_TAG}" \
			"${GCP_IMAP_SOURCE_RANGES}" \
			"${GCP_IMAP_ALLOW}"
		maybe_tag_instance "${GCP_IMAP_TARGET_TAG}"
	fi
	if [ "${GCP_ENSURE_IMAPS_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_IMAPS_FW_RULE_NAME}" \
			"${GCP_IMAPS_TARGET_TAG}" \
			"${GCP_IMAPS_SOURCE_RANGES}" \
			"${GCP_IMAPS_ALLOW}"
		maybe_tag_instance "${GCP_IMAPS_TARGET_TAG}"
	fi
	if [ "${GCP_ENSURE_HTTPS_FW}" = "1" ]; then
		gcp_maybe_create_public_fw \
			"${GCP_PROJECT_ID}" \
			"${GCP_NETWORK}" \
			"${GCP_HTTPS_FW_RULE_NAME}" \
			"${GCP_HTTPS_TARGET_TAG}" \
			"${GCP_HTTPS_SOURCE_RANGES}" \
			"${GCP_HTTPS_ALLOW}"
		maybe_tag_instance "${GCP_HTTPS_TARGET_TAG}"
	fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	init_vars
	ensure_runtime_shell "$@"
	parse_args "$@"
	validate_args
	ensure_fw_rules
}

main "$@"

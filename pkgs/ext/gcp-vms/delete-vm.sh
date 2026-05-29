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
	GCP_ZONE=""
	KEEP_DISK_LIST="none"
	KEEP_FW_RULES="0"
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
	cat <<'EOF'
Usage:
  pkgs/ext/gcp-vms/delete-vm.sh --name <instance> [--project <project>] [options]

Deletes an ad hoc VM created by pkgs/ext/gcp-vms/create-vm.sh. By default it
deletes all resources this tooling may have created, while avoiding shared
fw rules that still appear to be used by another instance.

Required:
  --name <instance>              GCE instance name.

Options:
  --project <project>            GCP project ID. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --zone <zone>                  Optional GCP zone. Defaults to auto-discovery
                                  by instance name.
  --all                          Delete instance, attached disks, and unused
                                  created fw rules. This is the default.
  --keep-disk=<csv>              Preserve selected disks. Default:
                                  --keep-disk=none.
                                  Use boot for the boot disk, or disk names:
                                  --keep-disk=boot
                                  --keep-disk=my-data-disk,boot
  --keep-fw-rules                Preserve fw rules.
  --fw-target-tag <tag>          Default: configured in pkgs/ext/gcp-vms/common.sh
  --fw-rule-name <name>          Default: configured in pkgs/ext/gcp-vms/common.sh
  --observability-fw-rule-name <name>
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --postgres-fw-rule-name <name>
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --nats-fw-rule-name <name>
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --wireguard-fw-rule-name <name>
  --wireguard-target-tag <tag>
  --smtp-fw-rule-name <name>
  --smtp-target-tag <tag>
  --smtps-fw-rule-name <name>
  --smtps-target-tag <tag>
  --imap-fw-rule-name <name>
  --imap-target-tag <tag>
  --imaps-fw-rule-name <name>
  --imaps-target-tag <tag>
                                  Defaults configured in pkgs/ext/gcp-vms/common.sh
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
		--project | --zone | --fw-target-tag | --fw-rule-name | --observability-fw-rule-name | --postgres-fw-rule-name | --nats-fw-rule-name | --wireguard-fw-rule-name | --wireguard-target-tag | --smtp-fw-rule-name | --smtp-target-tag | --smtps-fw-rule-name | --smtps-target-tag | --imap-fw-rule-name | --imap-target-tag | --imaps-fw-rule-name | --imaps-target-tag)
			gcp_apply_vm_value_arg "$1" "${2:-}"
			shift 2
			;;
		--all)
			KEEP_DISK_LIST="none"
			KEEP_FW_RULES="0"
			shift
			;;
		--keep-disk=*)
			KEEP_DISK_LIST="${1#*=}"
			shift
			;;
		--keep-disk)
			KEEP_DISK_LIST="${2:-}"
			gcp_need_value "$1" "${KEEP_DISK_LIST}"
			shift 2
			;;
		--keep-fw-rules)
			KEEP_FW_RULES="1"
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
	[ -n "${GCP_INSTANCE_NAME}" ] || gcp_die "--name is required"
	[ -n "${GCP_PROJECT_ID}" ] || gcp_die "No GCP project configured; pass --project or set GCP_DEFAULT_PROJECT_ID in pkgs/ext/gcp-vms/common.sh"
	if [ -z "${GCP_ZONE}" ]; then
		GCP_ZONE="$(gcp_discover_instance_zone "${GCP_PROJECT_ID}" "${GCP_INSTANCE_NAME}")"
	fi
}

# -----------------------------------------------------------------------------
# Instance and disk helpers
# -----------------------------------------------------------------------------

instance_json() {
	gcloud compute instances describe \
		"${GCP_INSTANCE_NAME}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--format=json
}

instance_disk_names() {
	local description_json="$1"

	jq -r '
		.disks[]
		| (.source | split("/")[-1])
	' <<<"${description_json}"
}

instance_boot_disk_name() {
	local description_json="$1"

	jq -r '
		.disks[]
		| select(.boot == true)
		| (.source | split("/")[-1])
	' <<<"${description_json}"
}

disk_exists() {
	local disk_name="$1"

	gcloud compute disks describe \
		"${disk_name}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" >/dev/null 2>&1
}

disk_in_use() {
	local disk_name="$1" users=""

	users="$(
		gcloud compute disks describe \
			"${disk_name}" \
			--project "${GCP_PROJECT_ID}" \
			--zone "${GCP_ZONE}" \
			--format='value(users[])' 2>/dev/null || true
	)"
	[ -n "${users}" ]
}

disk_should_keep() {
	local disk_name="$1" boot_disk_name="$2"
	local token=""

	[ -n "${KEEP_DISK_LIST}" ] || return 1
	[ "${KEEP_DISK_LIST}" != "none" ] || return 1

	while IFS= read -r token; do
		token="${token// /}"
		[ -n "${token}" ] || continue
		[ "${token}" != "none" ] || continue
		if [ "${token}" = "boot" ] && [ "${disk_name}" = "${boot_disk_name}" ]; then
			return 0
		fi
		if [ "${token}" = "${disk_name}" ]; then
			return 0
		fi
	done < <(tr ',' '\n' <<<"${KEEP_DISK_LIST}")

	return 1
}

set_disk_auto_delete_off() {
	local disk_name="$1"

	gcp_log "Preserving disk ${disk_name}"
	gcloud compute instances set-disk-auto-delete \
		"${GCP_INSTANCE_NAME}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--disk "${disk_name}" \
		--no-auto-delete >/dev/null
}

preserve_kept_attached_disks() {
	local description_json="$1" boot_disk_name="$2" disk_name=""

	while IFS= read -r disk_name; do
		[ -n "${disk_name}" ] || continue
		if disk_should_keep "${disk_name}" "${boot_disk_name}"; then
			set_disk_auto_delete_off "${disk_name}"
		fi
	done < <(instance_disk_names "${description_json}")
}

delete_disk_if_unused() {
	local disk_name="$1"

	[ -n "${disk_name}" ] || return 0
	if ! disk_exists "${disk_name}"; then
		return 0
	fi
	if disk_in_use "${disk_name}"; then
		gcp_log "Keeping disk ${disk_name}; it is still attached"
		return 0
	fi

	gcp_log "Deleting disk ${disk_name}"
	gcloud compute disks delete \
		"${disk_name}" \
		--project "${GCP_PROJECT_ID}" \
		--zone "${GCP_ZONE}" \
		--quiet >/dev/null
}

delete_attached_disks_if_unused() {
	local description_json="$1" boot_disk_name="$2" disk_name=""

	while IFS= read -r disk_name; do
		[ -n "${disk_name}" ] || continue
		if disk_should_keep "${disk_name}" "${boot_disk_name}"; then
			gcp_log "Keeping disk ${disk_name}"
			continue
		fi
		delete_disk_if_unused "${disk_name}"
	done < <(instance_disk_names "${description_json}")
}

delete_created_fw_rules() {
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_FW_RULE_NAME}" "${GCP_FW_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_OBSERVABILITY_FW_RULE_NAME}" "${GCP_FW_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_POSTGRES_FW_RULE_NAME}" "${GCP_FW_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_NATS_FW_RULE_NAME}" "${GCP_FW_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_WIREGUARD_FW_RULE_NAME}" "${GCP_WIREGUARD_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_SMTP_FW_RULE_NAME}" "${GCP_SMTP_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_SMTPS_FW_RULE_NAME}" "${GCP_SMTPS_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_IMAP_FW_RULE_NAME}" "${GCP_IMAP_TARGET_TAG}"
	gcp_delete_fw_rule_if_unused "${GCP_PROJECT_ID}" "${GCP_IMAPS_FW_RULE_NAME}" "${GCP_IMAPS_TARGET_TAG}"
}

# -----------------------------------------------------------------------------
# Delete orchestration
# -----------------------------------------------------------------------------

delete_instance() {
	local description_json="" boot_disk_name=""

	if [ -z "${GCP_ZONE}" ]; then
		gcp_log "Instance ${GCP_INSTANCE_NAME} does not exist in ${GCP_PROJECT_ID}; no zone-specific resources found"
	elif ! description_json="$(instance_json 2>/dev/null)"; then
		gcp_log "Instance ${GCP_INSTANCE_NAME} does not exist in ${GCP_PROJECT_ID}/${GCP_ZONE}"
	else
		boot_disk_name="$(instance_boot_disk_name "${description_json}")"
		preserve_kept_attached_disks "${description_json}" "${boot_disk_name}"

		gcp_log "Deleting GCP instance ${GCP_INSTANCE_NAME}"
		gcloud compute instances delete \
			"${GCP_INSTANCE_NAME}" \
			--project "${GCP_PROJECT_ID}" \
			--zone "${GCP_ZONE}" \
			--quiet >/dev/null

		delete_attached_disks_if_unused "${description_json}" "${boot_disk_name}"
	fi

	if [ "${KEEP_FW_RULES}" != "1" ]; then
		delete_created_fw_rules
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
	delete_instance
}

main "$@"

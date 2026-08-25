#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
	SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd -P)"
	COMMON_PATH="${SCRIPT_DIR}/../common.sh"
	# shellcheck source=pkgs/ext/gcp-vms/common.sh
	source "${COMMON_PATH}"
	gcp_init_defaults
	gcp_init_vm_config_defaults

	TEST_TMP_DIR="$(gcp_make_tmp_dir "gcp-vms-test")"
	MOCK_RULE_STATE="missing"
	MOCK_INSTANCE_HAS_TAG="0"
	MOCK_CREATE_CALLS="0"
	MOCK_ADD_TAG_CALLS="0"
	MOCK_DELETE_CALLS="0"
	MOCK_INSTANCE_LIST_ERROR="0"
	GCP_FIREWALL_DRY_RUN="0"

	GOOD_RULE_JSON='{"network":"https://www.googleapis.com/compute/v1/projects/pvl-net/global/networks/default","direction":"INGRESS","disabled":false,"sourceRanges":["0.0.0.0/0"],"targetTags":["allow-jitsi-media"],"allowed":[{"IPProtocol":"udp","ports":["10000"]}]}'
}

cleanup() {
	gcp_cleanup_tmp_dir "${TEST_TMP_DIR:-}"
}

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="$1" actual="$2" context="$3"

	[ "${actual}" = "${expected}" ] ||
		fail "${context}: expected ${expected}, got ${actual}"
}

assert_contains() {
	local haystack="$1" needle="$2" context="$3"

	[[ "${haystack}" == *"${needle}"* ]] ||
		fail "${context}: missing ${needle}"
}

mock_rule_json() {
	case "${MOCK_RULE_STATE}" in
	good) printf '%s\n' "${GOOD_RULE_JSON}" ;;
	drift-port) jq -c '.allowed[0].ports = ["9999"]' <<<"${GOOD_RULE_JSON}" ;;
	drift-network) jq -c '.network = "projects/pvl-net/global/networks/other"' <<<"${GOOD_RULE_JSON}" ;;
	drift-direction) jq -c '.direction = "EGRESS"' <<<"${GOOD_RULE_JSON}" ;;
	drift-disabled) jq -c '.disabled = true' <<<"${GOOD_RULE_JSON}" ;;
	drift-source) jq -c '.sourceRanges = ["10.0.0.0/8"]' <<<"${GOOD_RULE_JSON}" ;;
	drift-tag) jq -c '.targetTags = ["other"]' <<<"${GOOD_RULE_JSON}" ;;
	*) return 1 ;;
	esac
}

gcloud() {
	local operation="${1:-} ${2:-} ${3:-}"

	case "${operation}" in
	"compute firewall-rules list")
		if [ "${MOCK_RULE_STATE}" = "lookup-error" ]; then
			return 42
		fi
		if rule_json="$(mock_rule_json)"; then
			jq -c --arg name "allow-jitsi-media" '. + {name: $name} | [.]' <<<"${rule_json}"
		else
			printf '[]\n'
		fi
		;;
	"compute firewall-rules describe")
		mock_rule_json
		;;
	"compute firewall-rules create")
		MOCK_CREATE_CALLS=$((MOCK_CREATE_CALLS + 1))
		MOCK_RULE_STATE="good"
		;;
	"compute firewall-rules delete")
		MOCK_DELETE_CALLS=$((MOCK_DELETE_CALLS + 1))
		MOCK_RULE_STATE="missing"
		;;
	"compute instances describe")
		if [ "${MOCK_INSTANCE_HAS_TAG}" = "1" ]; then
			printf '{"tags":{"items":["allow-jitsi-media"]}}\n'
		else
			printf '{"tags":{"items":[]}}\n'
		fi
		;;
	"compute instances add-tags")
		MOCK_ADD_TAG_CALLS=$((MOCK_ADD_TAG_CALLS + 1))
		MOCK_INSTANCE_HAS_TAG="1"
		;;
	"compute instances list")
		if [ "${MOCK_INSTANCE_LIST_ERROR}" = "1" ]; then
			return 43
		fi
		return 0
		;;
	*)
		fail "unexpected gcloud call: $*"
		;;
	esac
}

test_defaults_and_create_tags() {
	assert_eq "allow-jitsi-media" "${GCP_JITSI_MEDIA_FW_RULE_NAME}" "default rule name"
	assert_eq "allow-jitsi-media" "${GCP_JITSI_MEDIA_TARGET_TAG}" "default target tag"
	assert_eq "0.0.0.0/0" "${GCP_JITSI_MEDIA_SOURCE_RANGES}" "default source range"
	assert_eq "udp:10000" "${GCP_JITSI_MEDIA_ALLOW}" "default allow tuple"

	GCP_ENSURE_JITSI_MEDIA_FW="1"
	GCP_TAGS="allow-https,allow-jitsi-media"
	gcp_finalize_vm_config
	assert_eq "allow-https,allow-jitsi-media" "${GCP_TAGS}" "create tag is unique"
}

test_create_and_read_back() {
	MOCK_RULE_STATE="missing"
	MOCK_CREATE_CALLS="0"
	gcp_maybe_create_public_fw \
		pvl-net default allow-jitsi-media allow-jitsi-media 0.0.0.0/0 udp:10000
	assert_eq "1" "${MOCK_CREATE_CALLS}" "missing rule creation count"
	assert_eq "good" "${MOCK_RULE_STATE}" "created rule read-back state"
}

test_existing_rule_is_validated() {
	MOCK_RULE_STATE="good"
	MOCK_CREATE_CALLS="0"
	gcp_maybe_create_public_fw \
		pvl-net default allow-jitsi-media allow-jitsi-media 0.0.0.0/0 udp:10000
	assert_eq "0" "${MOCK_CREATE_CALLS}" "valid rule reuse creation count"
}

test_drift_fails_closed() {
	local state="" error_file="${TEST_TMP_DIR}/drift.err"

	for state in \
		drift-port \
		drift-network \
		drift-direction \
		drift-disabled \
		drift-source \
		drift-tag; do
		MOCK_RULE_STATE="${state}"
		if (
			gcp_maybe_create_public_fw \
				pvl-net default allow-jitsi-media allow-jitsi-media 0.0.0.0/0 udp:10000
		) 2>"${error_file}"; then
			fail "${state} unexpectedly passed validation"
		fi
		assert_contains "$(<"${error_file}")" "Firewall rule drift detected" "${state} error"
	done
}

test_dry_run_is_read_only() {
	MOCK_RULE_STATE="missing"
	MOCK_CREATE_CALLS="0"
	MOCK_INSTANCE_HAS_TAG="0"
	MOCK_ADD_TAG_CALLS="0"
	GCP_FIREWALL_DRY_RUN="1"

	gcp_maybe_create_public_fw \
		pvl-net default allow-jitsi-media allow-jitsi-media 0.0.0.0/0 udp:10000
	gcp_add_instance_tag_if_missing pvl-net us-central1-a abird-edge allow-jitsi-media
	assert_eq "0" "${MOCK_CREATE_CALLS}" "dry-run rule creation count"
	assert_eq "0" "${MOCK_ADD_TAG_CALLS}" "dry-run tag mutation count"

	GCP_FIREWALL_DRY_RUN="0"
}

test_lookup_errors_fail_closed() {
	local error_file="${TEST_TMP_DIR}/lookup-error.err"

	MOCK_RULE_STATE="lookup-error"
	MOCK_CREATE_CALLS="0"
	if (
		gcp_maybe_create_public_fw \
			pvl-net default allow-jitsi-media allow-jitsi-media 0.0.0.0/0 udp:10000
	) 2>"${error_file}"; then
		fail "firewall lookup error unexpectedly planned a create"
	fi
	assert_contains "$(<"${error_file}")" "Unable to inspect fw rule" "lookup error"
	assert_eq "0" "${MOCK_CREATE_CALLS}" "lookup error creation count"
}

test_safe_delete() {
	MOCK_RULE_STATE="good"
	MOCK_DELETE_CALLS="0"
	gcp_delete_fw_rule_if_unused pvl-net allow-jitsi-media allow-jitsi-media
	assert_eq "1" "${MOCK_DELETE_CALLS}" "unused rule deletion count"
}

test_delete_lookup_errors_fail_closed() {
	local error_file="${TEST_TMP_DIR}/delete-lookup-error.err"

	MOCK_RULE_STATE="lookup-error"
	MOCK_DELETE_CALLS="0"
	if (gcp_delete_fw_rule_if_unused pvl-net allow-jitsi-media allow-jitsi-media) 2>"${error_file}"; then
		fail "delete firewall lookup error unexpectedly passed"
	fi
	assert_contains "$(<"${error_file}")" "Unable to inspect fw rule" "delete lookup error"
	assert_eq "0" "${MOCK_DELETE_CALLS}" "delete lookup error deletion count"

	MOCK_RULE_STATE="good"
	MOCK_INSTANCE_LIST_ERROR="1"
	if (gcp_delete_fw_rule_if_unused pvl-net allow-jitsi-media allow-jitsi-media) 2>"${error_file}"; then
		fail "instance lookup error unexpectedly deleted a firewall rule"
	fi
	assert_contains "$(<"${error_file}")" "Unable to inspect users" "tag user lookup error"
	assert_eq "0" "${MOCK_DELETE_CALLS}" "tag user lookup error deletion count"
	MOCK_INSTANCE_LIST_ERROR="0"
}

test_cli_contracts() {
	local help_text=""

	help_text="$(GCP_VMS_IN_NIX_SHELL=1 bash "${SCRIPT_DIR}/../create-vm.sh" --help)"
	assert_contains "${help_text}" "--ensure-jitsi-media-fw" "create-vm help"
	help_text="$(GCP_VMS_IN_NIX_SHELL=1 bash "${SCRIPT_DIR}/../ensure-firewall.sh" --help)"
	assert_contains "${help_text}" "--dry-run" "ensure-firewall help"
	assert_contains "${help_text}" "--jitsi-media-allow" "ensure-firewall help"
	help_text="$(GCP_VMS_IN_NIX_SHELL=1 bash "${SCRIPT_DIR}/../delete-vm.sh" --help)"
	assert_contains "${help_text}" "--jitsi-media-target-tag" "delete-vm help"
}

main() {
	init_vars
	trap cleanup EXIT
	test_defaults_and_create_tags
	test_create_and_read_back
	test_existing_rule_is_validated
	test_drift_fails_closed
	test_dry_run_is_read_only
	test_lookup_errors_fail_closed
	test_safe_delete
	test_delete_lookup_errors_fail_closed
	test_cli_contracts
	printf 'gcp-vms firewall tests passed\n'
}

main "$@"

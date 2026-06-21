#!/usr/bin/env bash
set -Eeuo pipefail

init_test_vars() {
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
	helper="${repo_root}/lib/podman-compose/helper.sh"
	tmp_root="${repo_root}/tmp"
	work_dir=""
	fake_bin=""
	compose_dir=""
	fake_state=""
}

cleanup() {
	if [ -n "${work_dir:-}" ]; then
		rm -rf "$work_dir"
	fi
}

setup_test_workspace() {
	mkdir -p "$tmp_root"
	work_dir="$(mktemp -d "${tmp_root}/podman-compose-helper-test.XXXXXX")"

	fake_bin="${work_dir}/bin"
	compose_dir="${work_dir}/compose"
	fake_state="${work_dir}/state"
	mkdir -p "$fake_bin" "$compose_dir"
}

write_fake_systemctl() {
	cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${1-}" = "--user" ] && [ "${2-}" = "show" ]; then
	printf '%s\n' "${TEST_TIMEOUT_VALUE:-5s}"
	exit 0
fi

printf 'unexpected systemctl args:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 64
EOF
	chmod +x "${fake_bin}/systemctl"
}

write_fake_podman() {
	cat >"${fake_bin}/podman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ -n "${NOTIFY_SOCKET-}" ] || [ -n "${WATCHDOG_PID-}" ] || [ -n "${WATCHDOG_USEC-}" ]; then
	printf '%s\n' "podman inherited systemd notify environment" >&2
	exit 70
fi

printf '%s\n' "$*" >"${TEST_PODMAN_ARGS_FILE}"

case "${TEST_PODMAN_MODE:-success}" in
success)
	printf '%s\n' "fake podman compose up ok"
	exit 0
	;;
fatal)
	printf '%s\n' 'Error: container name "stale" is already in use'
	sleep 30
	;;
timeout)
	sleep 30
	;;
*)
	printf '%s\n' "unknown TEST_PODMAN_MODE=${TEST_PODMAN_MODE}" >&2
	exit 64
	;;
esac
EOF
	chmod +x "${fake_bin}/podman"
}

setup_fake_bins() {
	write_fake_systemctl
	write_fake_podman
}

assert_file_contains() {
	local file="$1" expected="$2"

	if ! grep -Fxq -- "$expected" "$file"; then
		printf '%s\n' "expected ${file} to contain: ${expected}" >&2
		printf '%s\n' "actual:" >&2
		cat "$file" >&2
		exit 1
	fi
}

assert_path_exists() {
	local path="$1"

	if [ ! -e "$path" ]; then
		printf '%s\n' "expected path to exist: $path" >&2
		exit 1
	fi
}

assert_path_absent() {
	local path="$1"

	if [ -e "$path" ] || [ -L "$path" ]; then
		printf '%s\n' "expected path to be absent: $path" >&2
		exit 1
	fi
}

setup_helper_state() {
	init_vars
	PATH="${fake_bin}:$PATH"
	NOTIFY_SOCKET="/run/systemd/notify"
	WATCHDOG_PID="1234"
	WATCHDOG_USEC="1000000"
	TEST_PODMAN_ARGS_FILE="${fake_state}/podman-args"
	export PATH NOTIFY_SOCKET WATCHDOG_PID WATCHDOG_USEC TEST_PODMAN_ARGS_FILE

	mkdir -p "$fake_state"
	: >"$TEST_PODMAN_ARGS_FILE"
	runtime_dir="${work_dir}/runtime"
	working_dir="$compose_dir"
	generated_dir="${working_dir}/.podman-compose"
	lifecycle_lock_path="${generated_dir}/lifecycle.lock"
	state_path="${generated_dir}/state.json"
	podman_compose_service_name="test-compose"
	manifest_path="${runtime_dir}/podman-compose/${podman_compose_service_name}.manifest"
	compose_start_default_timeout_seconds=5
	compose_args=()
	compose_file_args=()
}

setup_metadata_file() {
	podman_compose_metadata="${fake_state}/metadata.json"
	mkdir -p "${runtime_dir}/podman-compose"
	cat >"$podman_compose_metadata" <<EOF
{
  "adoptionStamp": "${adoption_stamp}",
  "stagedDirs": [],
  "stagedFiles": []
}
EOF
}

run_success_test() {
	setup_helper_state
	TEST_PODMAN_MODE=success TEST_TIMEOUT_VALUE=5s compose_up_supervised normal
	assert_file_contains "$TEST_PODMAN_ARGS_FILE" "compose up -d --remove-orphans"
}

run_expected_failure_compose_test() {
	local mode="$1" timeout_value="$2" command_timeout="$3" default_timeout="$4" expected_failure_status

	setup_helper_state
	set +e
	# shellcheck disable=SC2016
	setsid env TEST_PODMAN_MODE="$mode" TEST_TIMEOUT_VALUE="$timeout_value" timeout "$command_timeout" bash -c '
		set -Eeuo pipefail
		source "$1"
		init_vars
		PATH="$2:$PATH"
		export PATH TEST_PODMAN_MODE TEST_TIMEOUT_VALUE TEST_PODMAN_ARGS_FILE
		runtime_dir="$3/runtime"
		working_dir="$3/compose"
		generated_dir="${working_dir}/.podman-compose"
		lifecycle_lock_path="${generated_dir}/lifecycle.lock"
		state_path="${generated_dir}/state.json"
		podman_compose_service_name="test-compose"
		compose_start_default_timeout_seconds="$4"
		compose_args=()
		compose_file_args=()
		compose_up_supervised normal
	' bash "$helper" "$fake_bin" "$work_dir" "$default_timeout"
	expected_failure_status="$?"
	set -e

	if [ "$expected_failure_status" -eq 0 ]; then
		printf '%s\n' "${mode} compose start unexpectedly succeeded" >&2
		exit 1
	fi
}

run_failed_start_cleanup_retry_test() {
	local staged_compose_file

	setup_helper_state
	adoption_stamp="test-adoption-stamp"
	setup_metadata_file
	mkdir -p "$working_dir/data" "$generated_dir"
	staged_compose_file="${working_dir}/compose.yml"
	printf '%s\n' "services: {}" >"$staged_compose_file"
	printf '%s\n' "$staged_compose_file" >"$manifest_path"
	record_staging_runtime_state
	assert_adoption_allowed
	if [ "$(jq -r '.startupPhase // ""' "$state_path")" != "staging" ]; then
		printf '%s\n' "expected failed-start state to record startupPhase=staging" >&2
		exit 1
	fi
	cleanup_runtime_files
	assert_path_absent "$staged_compose_file"
	assert_path_exists "$working_dir/data"
	assert_path_exists "$state_path"
	assert_adoption_allowed
}

run_tests() {
	run_success_test
	run_expected_failure_compose_test fatal 10s 5s 10
	run_expected_failure_compose_test timeout 2s 6s 2
	run_failed_start_cleanup_retry_test
}

main() {
	init_test_vars
	setup_test_workspace
	trap cleanup EXIT
	setup_fake_bins

	# shellcheck source=lib/podman-compose/helper.sh
	source "$helper"

	run_tests
	printf '%s\n' "podman-compose helper tests passed"
}

main "$@"

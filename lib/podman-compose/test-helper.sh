#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
helper="${repo_root}/lib/podman-compose/helper.sh"
tmp_root="${repo_root}/tmp"

mkdir -p "$tmp_root"
work_dir="$(mktemp -d "${tmp_root}/podman-compose-helper-test.XXXXXX")"
cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

fake_bin="${work_dir}/bin"
compose_dir="${work_dir}/compose"
fake_state="${work_dir}/state"
mkdir -p "$fake_bin" "$compose_dir"

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

# shellcheck source=lib/podman-compose/helper.sh
source "$helper"

assert_file_contains() {
	local file="$1" expected="$2"

	if ! grep -Fxq -- "$expected" "$file"; then
		printf '%s\n' "expected ${file} to contain: ${expected}" >&2
		printf '%s\n' "actual:" >&2
		cat "$file" >&2
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
	compose_start_default_timeout_seconds=5
	compose_args=()
	compose_file_args=()
}

setup_helper_state
TEST_PODMAN_MODE=success TEST_TIMEOUT_VALUE=5s compose_up_supervised normal
assert_file_contains "$TEST_PODMAN_ARGS_FILE" "compose up -d --remove-orphans"

setup_helper_state
# shellcheck disable=SC2016
if TEST_PODMAN_MODE=fatal TEST_TIMEOUT_VALUE=10s timeout 5s bash -c '
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
	compose_start_default_timeout_seconds=10
	compose_args=()
	compose_file_args=()
	compose_up_supervised normal
' bash "$helper" "$fake_bin" "$work_dir"; then
	printf '%s\n' "fatal compose output unexpectedly succeeded" >&2
	exit 1
fi

setup_helper_state
# shellcheck disable=SC2016
if TEST_PODMAN_MODE=timeout TEST_TIMEOUT_VALUE=2s timeout 6s bash -c '
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
	compose_start_default_timeout_seconds=2
	compose_args=()
	compose_file_args=()
	compose_up_supervised normal
' bash "$helper" "$fake_bin" "$work_dir"; then
	printf '%s\n' "timeout compose start unexpectedly succeeded" >&2
	exit 1
fi

printf '%s\n' "podman-compose helper tests passed"

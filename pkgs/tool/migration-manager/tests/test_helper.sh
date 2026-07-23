#!/usr/bin/env bash
set -Eeuo pipefail

TEST_TMP_DIR=""

cleanup() {
	if [ -n "$TEST_TMP_DIR" ]; then
		rm -rf "$TEST_TMP_DIR"
	fi
}

main() {
	local repo_root script_dir tmp_dir systemctl_log test_user
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
	repo_root="$(cd "$script_dir/../../../.." && pwd -P)"
	install -d -m 0755 "$repo_root/tmp"
	tmp_dir="$(mktemp -d "$repo_root/tmp/migration-manager-helper-test.XXXXXX")"
	TEST_TMP_DIR="$tmp_dir"
	trap cleanup EXIT
	systemctl_log="$tmp_dir/systemctl.log"
	test_user="$(id -un)"

	cat >"$tmp_dir/manifest.json" <<JSON
{
  "systemUnits": [
    {"unit": "stop-only.service", "stopOnDrain": true, "startOnResume": false},
    {"unit": "start-only.service", "stopOnDrain": false, "startOnResume": true},
    {"unit": "defaulted.service"}
  ],
  "userServices": [
    {"user": "${test_user}", "unit": "user-stop-only.service", "stopOnDrain": true, "startOnResume": false},
    {"user": "${test_user}", "unit": "user-start-only.service", "stopOnDrain": false, "startOnResume": true},
    {"user": "${test_user}", "unit": "user-defaulted.service"}
  ],
  "userTargets": [
    {"user": "${test_user}", "target": "abird-managed.target", "stopOnDrain": true, "startOnResume": true}
  ]
}
JSON

	cat >"$tmp_dir/systemctl" <<'SH'
#!/bin/sh
set -eu
if [ "$1" = show ] || { [ "$1" = --user ] && [ "$2" = show ]; }; then
	printf '%s\n' loaded
else
	printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?missing SYSTEMCTL_LOG}"
fi
SH
	chmod +x "$tmp_dir/systemctl"

	PATH="$tmp_dir:$PATH" \
		MIGRATION_MANAGER_GATE_PATH="$tmp_dir/gate" \
		MIGRATION_MANAGER_MANIFEST="$tmp_dir/manifest.json" \
		SYSTEMCTL_LOG="$systemctl_log" \
		XDG_RUNTIME_DIR="$tmp_dir/run" \
		bash "$repo_root/pkgs/tool/migration-manager/helper.sh" apply

	diff -u - "$systemctl_log" <<'EXPECTED'
start start-only.service
start defaulted.service
--user start user-start-only.service
--user start user-defaulted.service
--user start abird-managed.target
EXPECTED

	: >"$tmp_dir/gate"
	: >"$systemctl_log"
	PATH="$tmp_dir:$PATH" \
		MIGRATION_MANAGER_GATE_PATH="$tmp_dir/gate" \
		MIGRATION_MANAGER_MANIFEST="$tmp_dir/manifest.json" \
		SYSTEMCTL_LOG="$systemctl_log" \
		XDG_RUNTIME_DIR="$tmp_dir/run" \
		bash "$repo_root/pkgs/tool/migration-manager/helper.sh" apply

	diff -u - "$systemctl_log" <<'EXPECTED'
stop --wait stop-only.service
stop --wait defaulted.service
--user stop --wait abird-managed.target
--user stop --wait user-stop-only.service
--user stop --wait user-defaulted.service
EXPECTED
}

main "$@"

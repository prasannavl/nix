#!/usr/bin/env bash
set -Eeuo pipefail

TEST_TMP_DIR=""

cleanup() {
	if [ -n "$TEST_TMP_DIR" ]; then
		rm -rf "$TEST_TMP_DIR"
	fi
}

main() {
	local repo_root script_dir tmp_dir systemctl_log
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
	repo_root="$(cd "$script_dir/../../../.." && pwd -P)"
	install -d -m 0755 "$repo_root/tmp"
	tmp_dir="$(mktemp -d "$repo_root/tmp/migrator-helper-test.XXXXXX")"
	TEST_TMP_DIR="$tmp_dir"
	trap cleanup EXIT
	systemctl_log="$tmp_dir/systemctl.log"

	cat >"$tmp_dir/manifest.json" <<'JSON'
{
  "systemUnits": [
    {"unit": "stop-only.service", "stopOnDrain": true, "startOnResume": false},
    {"unit": "start-only.service", "stopOnDrain": false, "startOnResume": true},
    {"unit": "defaulted.service"}
  ],
  "dispatcherUnits": ["systemd-user-manager-dispatcher-abird.service"]
}
JSON

	cat >"$tmp_dir/systemctl" <<'SH'
#!/bin/sh
set -eu
case "$1" in
show)
	printf '%s\n' loaded
	;;
*)
	printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?missing SYSTEMCTL_LOG}"
	;;
esac
SH
	chmod +x "$tmp_dir/systemctl"

	PATH="$tmp_dir:$PATH" \
		MIGRATOR_GATE_PATH="$tmp_dir/gate" \
		MIGRATOR_MANIFEST="$tmp_dir/manifest.json" \
		SYSTEMCTL_LOG="$systemctl_log" \
		bash "$repo_root/pkgs/tool/migration-manager/migrator-helper.sh" apply

	diff -u - "$systemctl_log" <<'EXPECTED'
start start-only.service
start defaulted.service
restart systemd-user-manager-dispatcher-abird.service
EXPECTED

	: >"$tmp_dir/gate"
	: >"$systemctl_log"
	PATH="$tmp_dir:$PATH" \
		MIGRATOR_GATE_PATH="$tmp_dir/gate" \
		MIGRATOR_MANIFEST="$tmp_dir/manifest.json" \
		SYSTEMCTL_LOG="$systemctl_log" \
		bash "$repo_root/pkgs/tool/migration-manager/migrator-helper.sh" apply

	diff -u - "$systemctl_log" <<'EXPECTED'
stop --wait stop-only.service
stop --wait defaulted.service
restart systemd-user-manager-dispatcher-abird.service
EXPECTED
}

main "$@"

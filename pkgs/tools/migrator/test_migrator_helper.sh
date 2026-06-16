#!/usr/bin/env bash
set -Eeuo pipefail

main() {
	local repo_root tmp_dir systemctl_log
	repo_root="$(git rev-parse --show-toplevel)"
	install -d -m 0755 "$repo_root/tmp"
	tmp_dir="$(mktemp -d "$repo_root/tmp/migrator-helper-test.XXXXXX")"
	trap "rm -rf '$tmp_dir'" EXIT
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
#!/usr/bin/env bash
set -Eeuo pipefail
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
		bash "$repo_root/pkgs/tools/migrator/migrator-helper.sh" apply

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
		bash "$repo_root/pkgs/tools/migrator/migrator-helper.sh" apply

	diff -u - "$systemctl_log" <<'EXPECTED'
stop --wait stop-only.service
stop --wait defaulted.service
restart systemd-user-manager-dispatcher-abird.service
EXPECTED
}

main "$@"

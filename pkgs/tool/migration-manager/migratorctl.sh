#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	gate_path="${MIGRATOR_GATE_PATH:-}"
	apply_unit="migrator-apply.service"
	ssh_age_identity="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
	repo_root="${MIGRATOR_REPO_ROOT:-$(pwd -P)}"
	nixbot_config="${MIGRATOR_NIXBOT_CONFIG:-hosts/nixbot.nix}"
	tmp_files=()
}

cleanup() {
	local path=""
	for path in "${tmp_files[@]}"; do
		[ -n "$path" ] || continue
		rm -f "$path"
	done
}

log() {
	printf '%s\n' "[migratorctl] $*" >&2
}

make_temp_file() {
	local tmp_file=""
	tmp_file="$(mktemp)"
	tmp_files+=("$tmp_file")
	printf '%s\n' "$tmp_file"
}

ensure_gate_parent() {
	require_gate_path
	install -d -m 0755 "$(dirname "$gate_path")"
}

require_gate_path() {
	[ -n "$gate_path" ] || {
		printf '%s\n' "missing MIGRATOR_GATE_PATH" >&2
		exit 1
	}
}

set_local_gate() {
	local state="$1"
	ensure_gate_parent
	case "$state" in
	on)
		: >"$gate_path"
		;;
	off)
		rm -f "$gate_path"
		;;
	*)
		printf '%s\n' "unsupported gate state: $state" >&2
		exit 1
		;;
	esac
}

local_status() {
	require_gate_path
	if [ -f "$gate_path" ]; then
		printf '%s\n' on
	else
		printf '%s\n' off
	fi
}

local_apply() {
	systemctl restart --wait "$apply_unit"
}

load_nixbot_host_json() {
	local host="$1"
	local config_path="$repo_root/$nixbot_config"
	local config_path_json host_json expr
	config_path_json="$(jq -Rn --arg value "$config_path" '$value')"
	host_json="$(jq -Rn --arg value "$host" '$value')"
	expr="$(
		cat <<EOF
let
  cfg = import ${config_path_json};
  hostName = ${host_json};
  defaults = cfg.defaults or {};
  hostCfg =
    if builtins.hasAttr hostName cfg.hosts
    then cfg.hosts."\${hostName}"
    else throw "unknown nixbot host: \${hostName}";
  fallback = key: default:
    if builtins.hasAttr key hostCfg then hostCfg."\${key}"
    else if builtins.hasAttr key defaults then defaults."\${key}"
    else default;
in {
  user = fallback "user" "nixbot";
  target = hostCfg.target;
  port = fallback "port" 22;
  key = fallback "key" "";
  knownHosts = fallback "knownHosts" "";
  proxyJump = hostCfg.proxyJump or "";
  proxyCommand = hostCfg.proxyCommand or "";
}
EOF
	)"
	nix eval --impure --json --expr "$expr"
}

decrypt_identity_if_needed() {
	local input_path="$1"
	local output_var="$2"
	local tmp_file=""
	local resolved_path="$input_path"

	if [ -z "$input_path" ]; then
		printf -v "$output_var" '%s' ""
		return 0
	fi

	if [[ "$resolved_path" != /* ]]; then
		resolved_path="$repo_root/$resolved_path"
	fi

	if [[ "$input_path" != *.age ]]; then
		printf -v "$output_var" '%s' "$resolved_path"
		return 0
	fi

	tmp_file="$(make_temp_file)"
	age --decrypt -i "$ssh_age_identity" -o "$tmp_file" "$resolved_path"
	chmod 0600 "$tmp_file"
	printf -v "$output_var" '%s' "$tmp_file"
}

known_hosts_file_from_host_json() {
	local host_json="$1"
	local known_hosts=""
	local known_hosts_file=""

	known_hosts="$(jq -r '.knownHosts // ""' <<<"$host_json")"
	if [ -z "$known_hosts" ] || [ "$known_hosts" = "null" ]; then
		printf '%s\n' ""
		return 0
	fi

	known_hosts_file="$(make_temp_file)"
	printf '%s\n' "$known_hosts" >"$known_hosts_file"
	chmod 0600 "$known_hosts_file"
	printf '%s\n' "$known_hosts_file"
}

build_proxy_script() {
	local jump_host="$1"
	local jump_json=""
	local jump_user=""
	local jump_target=""
	local proxy_script=""
	local -a jump_opts=()

	jump_json="$(load_nixbot_host_json "$jump_host")"
	jump_user="$(jq -r '.user' <<<"$jump_json")"
	jump_target="$(jq -r '.target' <<<"$jump_json")"
	mapfile -d '' -t jump_opts < <(ssh_opts_from_host_json "$jump_json")

	proxy_script="$(make_temp_file)"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -Eeuo pipefail'
		printf '%s\n' "target_host=\"\${1:?missing target host}\""
		printf '%s\n' "target_port=\"\${2:?missing target port}\""
		printf 'exec ssh '
		printf '%q ' "${jump_opts[@]}"
		printf '%q ' "${jump_user}@${jump_target}"
		printf '%s\n' "-W \"\$target_host:\$target_port\""
	} >"$proxy_script"
	chmod 0700 "$proxy_script"
	printf '%s\n' "$proxy_script"
}

ssh_opts_from_host_json() {
	local host_json="$1"
	local identity_file=""
	local known_hosts_file=""
	local proxy_jump=""
	local proxy_command=""
	local proxy_script=""
	decrypt_identity_if_needed "$(jq -r '.key // ""' <<<"$host_json")" identity_file
	known_hosts_file="$(known_hosts_file_from_host_json "$host_json")"

	local -a opts=(
		-o BatchMode=yes
		-p "$(jq -r '.port' <<<"$host_json")"
	)

	if [ -n "$known_hosts_file" ]; then
		opts+=(
			-o StrictHostKeyChecking=yes
			-o "UserKnownHostsFile=$known_hosts_file"
		)
	else
		opts+=(-o StrictHostKeyChecking=accept-new)
	fi

	if [ -n "$identity_file" ]; then
		opts+=(-i "$identity_file")
	fi

	proxy_jump="$(jq -r '.proxyJump // ""' <<<"$host_json")"
	if [ -n "$proxy_jump" ] && [ "$proxy_jump" != "null" ]; then
		proxy_script="$(build_proxy_script "$proxy_jump")"
		opts+=(-o "ProxyCommand=$proxy_script %h %p")
		printf '%s\0' "${opts[@]}"
		return 0
	fi

	proxy_command="$(jq -r '.proxyCommand // ""' <<<"$host_json")"
	if [ -n "$proxy_command" ] && [ "$proxy_command" != "null" ]; then
		opts+=(-o "ProxyCommand=$proxy_command")
	fi

	printf '%s\0' "${opts[@]}"
}

remote_exec() {
	local host="$1"
	shift

	local host_json=""
	host_json="$(load_nixbot_host_json "$host")"
	local target user
	target="$(jq -r '.target' <<<"$host_json")"
	user="$(jq -r '.user' <<<"$host_json")"

	local -a ssh_opts=()
	mapfile -d '' -t ssh_opts < <(ssh_opts_from_host_json "$host_json")
	# shellcheck disable=SC2029
	ssh "${ssh_opts[@]}" "${user}@${target}" "$@"
}

remote_usage() {
	printf '%s\n' "usage: migratorctl remote <on|off|apply|status> --host <nixbot-host>" >&2
	exit 1
}

remote_main() {
	local action="${1:-}"
	shift || true
	local host=""

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--host)
			[ -n "${2:-}" ] || remote_usage
			host="${2:-}"
			shift 2
			;;
		--repo-root)
			[ -n "${2:-}" ] || remote_usage
			repo_root="${2:-}"
			shift 2
			;;
		--config)
			[ -n "${2:-}" ] || remote_usage
			nixbot_config="${2:-}"
			shift 2
			;;
		*)
			remote_usage
			;;
		esac
	done

	[ -n "$host" ] || remote_usage

	case "$action" in
	on | off | apply | status)
		remote_exec "$host" sudo /run/current-system/sw/bin/migratorctl "$action"
		;;
	*)
		remote_usage
		;;
	esac
}

main() {
	local action="${1:-}"
	init_vars
	trap cleanup EXIT

	case "$action" in
	on)
		set_local_gate on
		local_apply
		;;
	off)
		set_local_gate off
		local_apply
		;;
	apply)
		local_apply
		;;
	status)
		local_status
		;;
	remote)
		shift
		remote_main "$@"
		;;
	*)
		printf '%s\n' "usage: migratorctl {on|off|apply|status|remote}" >&2
		exit 1
		;;
	esac
}

main "$@"

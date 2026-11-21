#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage:
  wg-helper health --interface NAME --local-address ADDR --peer-host HOST --peer-port PORT [options]
  wg-helper heal --interface NAME --stale-after SECONDS --probe-host HOST --probe-port PORT

Commands:
  health  Verify a stable WireGuard deploy route during NixOS switch.
  heal    Rotate the local listen port when the latest handshake is stale.

Health options:
  --attempts N       TCP probe attempts. Default: 3.
  --delay SECONDS    Delay between attempts. Default: 2.
USAGE
}

die() {
	echo "error: $*" >&2
	exit 1
}

need_value() {
	[ "$#" -ge 2 ] || die "missing value for $1"
}

require_positive_integer() {
	local name="$1" value="$2"

	[[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "${name} must be a positive integer"
}

require_nonnegative_integer() {
	local name="$1" value="$2"

	[[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an integer"
}

probe_tcp() {
	local host="$1" port="$2"

	# shellcheck disable=SC2016
	timeout 5 bash -c 'cat </dev/null >/dev/tcp/"$1"/"$2"' _ "${host}" "${port}" >/dev/null 2>&1
}

assert_wireguard_interface() {
	local interface="$1" wg_error=""

	ip link show dev "${interface}" >/dev/null 2>&1 ||
		die "interface ${interface} is missing"
	if ! wg_error="$(wg show "${interface}" 2>&1 >/dev/null)"; then
		die "interface ${interface} is not accessible as WireGuard interface: ${wg_error:-wg show failed}"
	fi
}

assert_interface_address() {
	local interface="$1" local_address="$2" addr_output=""

	addr_output="$(ip -o -4 addr show dev "${interface}" 2>/dev/null || true)"
	[[ " ${addr_output} " == *" ${local_address}/"* ]] ||
		die "interface ${interface} does not own ${local_address}"
}

assert_peer_route() {
	local interface="$1" peer_host="$2" route_output=""

	route_output="$(ip route get "${peer_host}" 2>/dev/null || true)"
	[[ " ${route_output} " == *" dev ${interface} "* ]] ||
		die "route to ${peer_host} does not use ${interface}: ${route_output}"
}

latest_handshake_epoch() {
	local interface="$1"

	wg show "${interface}" latest-handshakes 2>/dev/null |
		awk 'BEGIN { latest = 0 } { if ($2 > latest) latest = $2 } END { print latest }'
}

rotate_listen_port() {
	local interface="$1" current_port="" next_port=""

	current_port="$(wg show "${interface}" listen-port 2>/dev/null || true)"
	[[ "${current_port}" =~ ^[0-9]+$ ]] || current_port=51820
	next_port=$((current_port + 1))
	if [ "${next_port}" -gt 51920 ]; then
		next_port=51820
	fi

	echo "rotating ${interface} listen-port ${current_port} -> ${next_port}"
	wg set "${interface}" listen-port "${next_port}"
}

health_command() {
	local interface="" local_address="" peer_host="" peer_port="" attempts="3" delay="2" attempt=""

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--interface)
			need_value "$@"
			interface="$2"
			shift 2
			;;
		--local-address)
			need_value "$@"
			local_address="$2"
			shift 2
			;;
		--peer-host)
			need_value "$@"
			peer_host="$2"
			shift 2
			;;
		--peer-port)
			need_value "$@"
			peer_port="$2"
			shift 2
			;;
		--attempts)
			need_value "$@"
			attempts="$2"
			shift 2
			;;
		--delay)
			need_value "$@"
			delay="$2"
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "unknown health argument: $1"
			;;
		esac
	done

	[ -n "${interface}" ] || die "--interface is required"
	[ -n "${local_address}" ] || die "--local-address is required"
	[ -n "${peer_host}" ] || die "--peer-host is required"
	[ -n "${peer_port}" ] || die "--peer-port is required"
	require_positive_integer "--peer-port" "${peer_port}"
	require_positive_integer "--attempts" "${attempts}"
	require_nonnegative_integer "--delay" "${delay}"

	assert_wireguard_interface "${interface}"
	assert_interface_address "${interface}" "${local_address}"
	assert_peer_route "${interface}" "${peer_host}"

	for ((attempt = 1; attempt <= attempts; attempt++)); do
		if probe_tcp "${peer_host}" "${peer_port}"; then
			echo "${peer_host}:${peer_port} reachable through ${interface}"
			return 0
		fi
		if [ "${attempt}" -lt "${attempts}" ]; then
			sleep "${delay}"
		fi
	done

	die "${peer_host}:${peer_port} is not reachable through ${interface}"
}

heal_command() {
	local interface="" stale_after="" probe_host="" probe_port="" latest="" now="" age="" wg_error=""

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--interface)
			need_value "$@"
			interface="$2"
			shift 2
			;;
		--stale-after)
			need_value "$@"
			stale_after="$2"
			shift 2
			;;
		--probe-host)
			need_value "$@"
			probe_host="$2"
			shift 2
			;;
		--probe-port)
			need_value "$@"
			probe_port="$2"
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "unknown heal argument: $1"
			;;
		esac
	done

	[ -n "${interface}" ] || die "--interface is required"
	[ -n "${stale_after}" ] || die "--stale-after is required"
	[ -n "${probe_host}" ] || die "--probe-host is required"
	[ -n "${probe_port}" ] || die "--probe-port is required"
	require_nonnegative_integer "--stale-after" "${stale_after}"
	require_positive_integer "--probe-port" "${probe_port}"

	if ! ip link show dev "${interface}" >/dev/null 2>&1; then
		echo "${interface} is missing; skipping WireGuard self-heal"
		return 0
	fi
	if ! wg_error="$(wg show "${interface}" 2>&1 >/dev/null)"; then
		echo "${interface} is not accessible as WireGuard interface; skipping WireGuard self-heal: ${wg_error:-wg show failed}"
		return 0
	fi

	latest="$(latest_handshake_epoch "${interface}")"
	now="$(date +%s)"
	if [ -z "${latest}" ] || [ "${latest}" -eq 0 ]; then
		age=$((stale_after + 1))
	else
		age=$((now - latest))
	fi

	if [ "${age}" -le "${stale_after}" ]; then
		echo "${interface} latest handshake age ${age}s <= ${stale_after}s; no action"
		return 0
	fi

	echo "${interface} latest handshake age ${age}s > ${stale_after}s; probing"
	if probe_tcp "${probe_host}" "${probe_port}"; then
		echo "${probe_host}:${probe_port} is reachable; no port rotation needed"
		return 0
	fi

	echo "${interface} latest handshake age ${age}s > ${stale_after}s; healing"
	rotate_listen_port "${interface}"
	probe_tcp "${probe_host}" "${probe_port}" ||
		die "${probe_host}:${probe_port} is unreachable after healing"
}

main() {
	local command="${1:-}"

	case "${command}" in
	health)
		shift
		health_command "$@"
		;;
	heal)
		shift
		heal_command "$@"
		;;
	--help | -h)
		usage
		;;
	"")
		usage
		exit 1
		;;
	*)
		die "unknown command: ${command}"
		;;
	esac
}

main "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	uplink_interface="${HOST_NETWORK_QOS_INTERFACE-}"
	ifb_interface="${HOST_NETWORK_QOS_IFB_INTERFACE-}"
	upload_bandwidth="${HOST_NETWORK_QOS_UPLOAD_BANDWIDTH-}"
	download_bandwidth="${HOST_NETWORK_QOS_DOWNLOAD_BANDWIDTH-}"
	dscp_mask="${HOST_NETWORK_QOS_DSCP_MASK-0xfc000000}"
	dscp_state_mask="${HOST_NETWORK_QOS_DSCP_STATE_MASK-0x01000000}"
}

require_value() {
	local name value
	name="$1"
	value="$2"

	if [ -z "$value" ]; then
		printf 'host-network-qos: %s is required\n' "$name" >&2
		return 1
	fi
}

validate_config() {
	require_value HOST_NETWORK_QOS_INTERFACE "$uplink_interface"
	require_value HOST_NETWORK_QOS_IFB_INTERFACE "$ifb_interface"
	require_value HOST_NETWORK_QOS_UPLOAD_BANDWIDTH "$upload_bandwidth"
	require_value HOST_NETWORK_QOS_DOWNLOAD_BANDWIDTH "$download_bandwidth"
}

delete_qdisc() {
	local device location
	device="$1"
	location="$2"

	tc qdisc del dev "$device" "$location" 2>/dev/null || true
}

remove_qos() {
	if ip link show dev "$uplink_interface" >/dev/null 2>&1; then
		delete_qdisc "$uplink_interface" ingress
		delete_qdisc "$uplink_interface" root
	fi

	if ip link show dev "$ifb_interface" >/dev/null 2>&1; then
		ip link set dev "$ifb_interface" down || true
		ip link delete dev "$ifb_interface" type ifb || true
	fi
}

check_qdisc() {
	local device expected output
	device="$1"
	expected="$2"
	output="$(tc qdisc show dev "$device")"

	grep -Eq "$expected" <<<"$output"
}

check_qos() {
	local filters

	check_qdisc "$uplink_interface" 'qdisc cake .* root '
	check_qdisc "$uplink_interface" 'qdisc ingress .* parent ffff:'
	check_qdisc "$ifb_interface" 'qdisc cake .* root '
	filters="$(tc filter show dev "$uplink_interface" parent ffff:)"
	grep -q 'ctinfo' <<<"$filters"
	grep -Eq "mirred.*[Rr]edirect.*${ifb_interface}" <<<"$filters"
}

configure_qos() {
	ip link show dev "$uplink_interface" >/dev/null || return
	ip link add name "$ifb_interface" type ifb || return
	ip link set dev "$ifb_interface" up || return

	tc qdisc replace dev "$ifb_interface" root cake \
		bandwidth "$download_bandwidth" \
		diffserv4 nat dual-dsthost ingress wash || return

	tc qdisc replace dev "$uplink_interface" root cake \
		bandwidth "$upload_bandwidth" \
		diffserv4 nat dual-srchost wash || return

	tc qdisc replace dev "$uplink_interface" handle ffff: ingress || return
	tc filter replace dev "$uplink_interface" parent ffff: protocol all pref 10 \
		matchall \
		action ctinfo dscp "$dscp_mask" "$dscp_state_mask" pipe \
		action mirred egress redirect dev "$ifb_interface" || return

	check_qos
}

apply_qos() {
	remove_qos
	if ! configure_qos; then
		printf 'host-network-qos: failed to configure %s; restoring defaults\n' \
			"$uplink_interface" >&2
		remove_qos
		return 1
	fi
}

usage() {
	printf 'Usage: host-network-qos {apply|check|remove}\n' >&2
}

main() {
	local command
	init_vars
	validate_config
	command="${1-}"

	case "$command" in
	apply)
		apply_qos
		;;
	check)
		check_qos
		;;
	remove)
		remove_qos
		;;
	*)
		usage
		return 2
		;;
	esac
}

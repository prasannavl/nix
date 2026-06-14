#!/usr/bin/env python3
import argparse
import fcntl
import ipaddress
import re
import subprocess
import sys
import time
from pathlib import Path


def run_nft_command(command, check=True):
    result = subprocess.run(
        ["nft", "-f", "-"],
        check=False,
        input=f"{command}\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "nft command failed")
    return result


def nft_element(action, table, set_name, value, timeout=None):
    element = value
    if timeout is not None:
        element = f"{value} timeout {timeout}s"
    return run_nft_command(
        f"{action} element inet {table} {set_name} {{ {element} }}",
        check=False,
    )


def replace_nft_element(table, set_name, value, timeout):
    nft_element("delete", table, set_name, value, None)
    result = nft_element("add", table, set_name, value, timeout)
    if result.returncode != 0 and "File exists" not in result.stderr:
        raise RuntimeError(result.stderr.strip() or "failed to add nft element")


def delete_nft_element(table, set_name, value):
    nft_element("delete", table, set_name, value, None)


def safe_prefix_name(prefix):
    return re.sub(r"[^0-9A-Fa-f_.-]", "_", prefix)


def prune_timestamps(values, now, find_time):
    floor = now - find_time
    kept = []
    for value in values:
        try:
            timestamp = int(value.strip())
        except ValueError:
            continue
        if timestamp >= floor:
            kept.append(timestamp)
    return kept


def record_prefix_hit(state_dir, prefix, find_time):
    state_dir.mkdir(parents=True, exist_ok=True)
    lock_path = state_dir / ".lock"
    prefix_path = state_dir / safe_prefix_name(prefix)
    now = int(time.time())

    with lock_path.open("a+") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        existing = prefix_path.read_text().splitlines() if prefix_path.exists() else []
        timestamps = prune_timestamps(existing, now, find_time)
        timestamps.append(now)
        prefix_path.write_text("".join(f"{value}\n" for value in timestamps))
        return len(timestamps)


def parse_ip(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise SystemExit(f"invalid IP address: {value}") from exc
    if address.version == 6 and address.ipv4_mapped is not None:
        return address.ipv4_mapped
    return address


def ban(args):
    address = parse_ip(args.ip)
    if address.version == 4:
        replace_nft_element(args.table, args.ipv4_exact_set, str(address), args.exact_timeout)
        return 0

    replace_nft_element(args.table, args.ipv6_exact_set, str(address), args.exact_timeout)
    prefix = str(ipaddress.ip_network(f"{address}/{args.ipv6_prefix_length}", strict=False))
    hit_count = record_prefix_hit(Path(args.state_dir), prefix, args.escalation_find_time)
    if hit_count >= args.escalation_max_retry:
        replace_nft_element(args.table, args.ipv6_prefix_set, prefix, args.prefix_timeout)
    return 0


def unban(args):
    address = parse_ip(args.ip)
    if address.version == 4:
        delete_nft_element(args.table, args.ipv4_exact_set, str(address))
    else:
        delete_nft_element(args.table, args.ipv6_exact_set, str(address))
    return 0


def normalize_key(args):
    address = parse_ip(args.ip)
    if address.version == 4:
        print(str(address))
    else:
        print(ipaddress.ip_network(f"{address}/{args.ipv6_prefix_length}", strict=False))
    return 0


def add_common_args(parser):
    parser.add_argument("--table", default="fail2ban_helper")
    parser.add_argument("--ipv4-exact-set", default="exact4")
    parser.add_argument("--ipv6-exact-set", default="exact6")
    parser.add_argument("--ipv6-prefix-set", default="prefix6")
    parser.add_argument("--ipv6-prefix-length", type=int, default=64)
    parser.add_argument("--state-dir", default="/var/lib/fail2ban/fail2ban-helper")
    parser.add_argument("--exact-timeout", type=int, default=600)
    parser.add_argument("--prefix-timeout", type=int, default=600)
    parser.add_argument("--escalation-find-time", type=int, default=600)
    parser.add_argument("--escalation-max-retry", type=int, default=3)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    ban_parser = subparsers.add_parser("ban")
    add_common_args(ban_parser)
    ban_parser.add_argument("--ip", required=True)
    ban_parser.set_defaults(func=ban)

    unban_parser = subparsers.add_parser("unban")
    add_common_args(unban_parser)
    unban_parser.add_argument("--ip", required=True)
    unban_parser.set_defaults(func=unban)

    key_parser = subparsers.add_parser("normalize-key")
    key_parser.add_argument("--ipv6-prefix-length", type=int, default=64)
    key_parser.add_argument("ip")
    key_parser.set_defaults(func=normalize_key)

    args = parser.parse_args()
    try:
        return args.func(args)
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

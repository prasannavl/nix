#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
usage: installer-to-disk --iso ISO --disk DISK [options]

Write an installer ISO to a whole USB disk, then create an encrypted persistence
partition in the remaining free space.

Required:
  --iso ISO                 Installer ISO to write.
  --disk DISK               Whole target disk, for example /dev/disk/by-id/usb-...

Options:
  --persistence-label LABEL LUKS label. Defaults to NIXOS_PERSIST.
  --persistence-mapper NAME Temporary mapper name. Defaults to nixos-persist.
  --persistence-size SIZE  Persistence size in GiB, max, or -GiB to leave free.
                           Defaults to max. Example: 32 uses 32 GiB;
                           -16 uses all remaining space except 16 GiB.
  --fs-label LABEL          Filesystem label inside LUKS. Defaults to nixos-persist-data.
  --partition-label LABEL   GPT partition label. Defaults to nixos-persistence.
  --key-file FILE           Use a key file for luksFormat/open instead of prompting.
  --no-persistence          Only write the ISO.
  --yes                     Do not ask for the destructive confirmation prompt.
  --dry-run                 Print commands without changing the disk.
  -h, --help                Show this help.

This script destroys DISK. Pass the whole disk, not a partition.
EOF
}

init_vars() {
	command_name="${INSTALLER_TO_DISK_COMMAND:-lib/installer/installer-to-disk.sh}"
	iso_path=""
	disk=""
	persistence=1
	persistence_label="NIXOS_PERSIST"
	persistence_mapper="nixos-persist"
	persistence_size="max"
	fs_label="nixos-persist-data"
	partition_label="nixos-persistence"
	key_file=""
	yes=0
	dry_run=0
	opened_mapper=0
	passphrase=""
	persistence_partition=""
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

ensure_runtime_shell() {
	local runtime_shell_flag="${INSTALLER_TO_DISK_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#bash
		nixpkgs#coreutils
		nixpkgs#cryptsetup
		nixpkgs#e2fsprogs
		nixpkgs#gawk
		nixpkgs#gptfdisk
		nixpkgs#nix
		nixpkgs#parted
		nixpkgs#systemd
		nixpkgs#util-linux
	)

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env INSTALLER_TO_DISK_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

require_cmds() {
	local cmd

	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
	done
}

validate_name() {
	local name="$1"

	[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid name: $name"
}

validate_label() {
	local label="$1"

	[ -n "$label" ] || die "Label must be non-empty"
	[[ "$label" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid label: $label"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--iso)
			[ "$#" -ge 2 ] || die "--iso requires a value"
			iso_path="$2"
			shift
			;;
		--iso=*)
			iso_path="${1#--iso=}"
			;;
		--disk)
			[ "$#" -ge 2 ] || die "--disk requires a value"
			disk="$2"
			shift
			;;
		--disk=*)
			disk="${1#--disk=}"
			;;
		--persistence-label)
			[ "$#" -ge 2 ] || die "--persistence-label requires a value"
			persistence_label="$2"
			shift
			;;
		--persistence-label=*)
			persistence_label="${1#--persistence-label=}"
			;;
		--persistence-mapper)
			[ "$#" -ge 2 ] || die "--persistence-mapper requires a value"
			persistence_mapper="$2"
			shift
			;;
		--persistence-mapper=*)
			persistence_mapper="${1#--persistence-mapper=}"
			;;
		--persistence-size)
			[ "$#" -ge 2 ] || die "--persistence-size requires a value"
			persistence_size="$2"
			shift
			;;
		--persistence-size=*)
			persistence_size="${1#--persistence-size=}"
			;;
		--fs-label)
			[ "$#" -ge 2 ] || die "--fs-label requires a value"
			fs_label="$2"
			shift
			;;
		--fs-label=*)
			fs_label="${1#--fs-label=}"
			;;
		--partition-label)
			[ "$#" -ge 2 ] || die "--partition-label requires a value"
			partition_label="$2"
			shift
			;;
		--partition-label=*)
			partition_label="${1#--partition-label=}"
			;;
		--key-file)
			[ "$#" -ge 2 ] || die "--key-file requires a value"
			key_file="$2"
			shift
			;;
		--key-file=*)
			key_file="${1#--key-file=}"
			;;
		--no-persistence)
			persistence=0
			;;
		--yes)
			yes=1
			;;
		--dry-run)
			dry_run=1
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			;;
		esac
		shift
	done
}

shell_quote_args() {
	local arg

	for arg in "$@"; do
		printf ' %q' "$arg"
	done
	printf '\n'
}

run_cmd() {
	printf 'Command:' >&2
	shell_quote_args "$@" >&2
	if [ "$dry_run" = 0 ]; then
		"$@"
	fi
}

require_root_for_write() {
	if [ "$dry_run" = 0 ] && [ "$(id -u)" -ne 0 ]; then
		die "Run as root, for example: sudo $command_name --iso ... --disk ..."
	fi
}

validate_args() {
	[ -n "$iso_path" ] || die "--iso is required"
	[ -n "$disk" ] || die "--disk is required"
	[ -r "$iso_path" ] || die "ISO is not readable: $iso_path"
	[ -b "$disk" ] || die "Disk is not a block device: $disk"
	[ "$(lsblk -dnro TYPE "$disk")" = "disk" ] || die "--disk must be a whole disk, not a partition: $disk"

	if [ "$persistence" = 1 ]; then
		validate_label "$persistence_label"
		validate_label "$fs_label"
		validate_label "$partition_label"
		validate_name "$persistence_mapper"
		if [ "$persistence_size" != "max" ]; then
			[[ "$persistence_size" =~ ^-?[1-9][0-9]*([Gg]([Bb])?)?$ ]] ||
				die "--persistence-size must be max, a positive GiB value, or a negative GiB reserve, for example 32 or -16"
		fi

		if [ -n "$key_file" ]; then
			[ -r "$key_file" ] || die "Key file is not readable: $key_file"
		fi
		if [ -e "/dev/mapper/$persistence_mapper" ]; then
			die "Mapper already exists: /dev/mapper/$persistence_mapper"
		fi
	fi
}

show_plan() {
	cat >&2 <<EOF
About to write installer media:
  ISO:        $iso_path
  Disk:       $disk
  Persistence: $persistence
EOF
	if [ "$persistence" = 1 ]; then
		cat >&2 <<EOF
  LUKS label: $persistence_label
  Mapper:     $persistence_mapper
  Size:       $persistence_size
  FS label:   $fs_label
EOF
	fi
	printf '\nCurrent target device tree:\n' >&2
	lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$disk" >&2
}

confirm_destructive_action() {
	local expected reply

	if [ "$dry_run" = 1 ] || [ "$yes" = 1 ]; then
		return
	fi

	expected="WIPE $disk"
	printf '\nThis will destroy all existing data on %s.\n' "$disk" >&2
	printf 'Type exactly "%s" to continue: ' "$expected" >&2
	IFS= read -r reply
	[ "$reply" = "$expected" ] || die "Confirmation did not match"
}

mounted_targets_for_disk() {
	lsblk -nrpo MOUNTPOINT "$disk" | awk 'NF > 0'
}

unmount_disk() {
	local target
	local targets=()

	while IFS= read -r target || [ -n "$target" ]; do
		[ -n "$target" ] && targets+=("$target")
	done < <(mounted_targets_for_disk | sort -r)

	for target in "${targets[@]}"; do
		run_cmd umount "$target"
	done
}

settle_devices() {
	if command -v udevadm >/dev/null 2>&1; then
		run_cmd udevadm settle
	fi
}

reread_partition_table() {
	run_cmd partprobe "$disk"
	settle_devices
}

write_iso() {
	unmount_disk
	run_cmd dd "if=$iso_path" "of=$disk" bs=4M status=progress conv=fsync
	run_cmd sync
	reread_partition_table
}

find_persistence_partition() {
	lsblk -nrpo NAME,PARTLABEL "$disk" | awk -v label="$partition_label" '$2 == label { print $1 }'
}

create_persistence_partition() {
	local end_sector
	local start_sector

	run_cmd sgdisk -e "$disk"
	if [ "$dry_run" = 1 ]; then
		printf 'Dry run would create the persistence partition in the free space left after writing the ISO.\n' >&2
		return
	fi

	read -r start_sector end_sector < <(persistence_partition_bounds)
	run_cmd sgdisk -n "0:$start_sector:$end_sector" -t 0:8309 -c "0:$partition_label" "$disk"
	reread_partition_table

	persistence_partition="$(find_persistence_partition | head -n 1)"
	[ -n "$persistence_partition" ] || die "Could not find partition labeled $partition_label after creating it"
}

persistence_size_gib() {
	local size="$persistence_size"

	size="${size%%[Gg]*}"
	printf '%s\n' "$size"
}

gib_to_sectors() {
	local gib="$1"
	local sector_size

	sector_size="$(blockdev --getss "$disk")"
	printf '%s\n' "$((gib * 1024 * 1024 * 1024 / sector_size))"
}

sectors_to_gib() {
	local sector_count="$1"
	local sector_size

	sector_size="$(blockdev --getss "$disk")"
	printf '%s\n' "$((sector_count * sector_size / 1024 / 1024 / 1024))"
}

persistence_partition_bounds() {
	local end_sector
	local free_sectors
	local requested_gib
	local requested_sectors
	local start_sector

	start_sector="$(sgdisk -F "$disk")"
	end_sector="$(sgdisk -E "$disk")"
	[ "$start_sector" -gt 0 ] || die "No free space remains on $disk for a persistence partition"
	[ "$end_sector" -ge "$start_sector" ] || die "No usable free space remains on $disk for a persistence partition"

	free_sectors="$((end_sector - start_sector + 1))"
	requested_gib="$(persistence_size_gib)"

	if [ "$requested_gib" = "max" ]; then
		:
	elif [[ "$requested_gib" == -* ]]; then
		requested_sectors="$(gib_to_sectors "${requested_gib#-}")"
		if [ "$free_sectors" -le "$requested_sectors" ]; then
			die "Cannot leave ${requested_gib#-} GiB free; only $(sectors_to_gib "$free_sectors") GiB is available after the ISO"
		fi
		end_sector="$((end_sector - requested_sectors))"
	else
		requested_sectors="$(gib_to_sectors "$requested_gib")"
		if [ "$free_sectors" -lt "$requested_sectors" ]; then
			die "Cannot create ${requested_gib} GiB persistence partition; only $(sectors_to_gib "$free_sectors") GiB is available after the ISO"
		fi
		end_sector="$((start_sector + requested_sectors - 1))"
	fi

	printf '%s %s\n' "$start_sector" "$end_sector"
}

format_persistence_partition() {
	local mapper_path

	if [ "$dry_run" = 1 ]; then
		printf 'Dry run would LUKS-format the new persistence partition and create ext4 inside it.\n' >&2
		return
	fi

	printf 'Persistence partition: %s\n' "$persistence_partition" >&2
	if [ -n "$key_file" ]; then
		run_cmd cryptsetup luksFormat --batch-mode --type luks2 --label "$persistence_label" --key-file "$key_file" "$persistence_partition"
		run_cmd cryptsetup open "$persistence_partition" "$persistence_mapper" --key-file "$key_file"
	else
		read_luks_passphrase
		run_cryptsetup_with_passphrase luksFormat --batch-mode --type luks2 --label "$persistence_label" --key-file - "$persistence_partition"
		run_cryptsetup_with_passphrase open "$persistence_partition" "$persistence_mapper" --key-file -
		passphrase=""
	fi
	opened_mapper=1

	mapper_path="/dev/mapper/$persistence_mapper"
	run_cmd mkfs.ext4 -F -L "$fs_label" "$mapper_path"
	run_cmd cryptsetup close "$persistence_mapper"
	opened_mapper=0
}

read_luks_passphrase() {
	local confirm

	printf 'Persistence LUKS passphrase: ' >&2
	IFS= read -rs passphrase
	printf '\n' >&2
	printf 'Confirm persistence LUKS passphrase: ' >&2
	IFS= read -rs confirm
	printf '\n' >&2

	[ -n "$passphrase" ] || die "Passphrase must be non-empty"
	[ "$passphrase" = "$confirm" ] || die "Passphrases did not match"
}

run_cryptsetup_with_passphrase() {
	printf 'Command: cryptsetup' >&2
	shell_quote_args "$@" >&2
	printf '%s' "$passphrase" | cryptsetup "$@"
}

cleanup() {
	if [ "$opened_mapper" = 1 ] && [ -e "/dev/mapper/$persistence_mapper" ]; then
		cryptsetup close "$persistence_mapper" || true
	fi
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	require_cmds awk blockdev dd id lsblk partprobe sort sync umount
	if [ "$persistence" = 1 ]; then
		require_cmds cryptsetup mkfs.ext4 sgdisk
	fi
	require_root_for_write
	validate_args
	show_plan
	confirm_destructive_action

	trap cleanup EXIT
	write_iso
	if [ "$persistence" = 1 ]; then
		create_persistence_partition
		format_persistence_partition
	fi
	run_cmd sync

	printf 'Installer disk is ready: %s\n' "$disk" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi

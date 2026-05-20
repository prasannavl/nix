#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/host-manager.sh generate --host HOST [--system=none|live|incus] [options]
  scripts/host-manager.sh live-install --host HOST --wipe-disks [options]
  scripts/host-manager.sh delete --host HOST [--force|--yes]

Examples:
  scripts/host-manager.sh generate --system=live --host pvl-a1 \
    --disk /dev/disk/by-id/nvme-Lexar_SSD_ARES_2TB_QEC053R000846P2222 \
    --swap-size-mib 65536

  scripts/host-manager.sh live-install --host pvl-a1 --wipe-disks

  scripts/host-manager.sh generate --host pvl-new --disk /dev/disk/by-id/nvme-...

  scripts/host-manager.sh generate --system=incus --incus-host pvl-x2 --host pvl-guest \
    --incus-ipv4 10.10.20.50

Actions:
  generate                 Create or update repo host config.
  live-install             Run live disko and nixos-install for an existing host.
  delete                   Remove host config, nixbot entry, age machine keys,
                           secret registration, and matching Incus instance.

Options:
  --host HOST              Host name.
  --system SYSTEM          Generate target type: none, live, or incus.
                           Default: none.
  --disk PATH              Stable target disk path. Adds physical disko sys.nix.
                           Without --system=live/--hardware-config, omitting this
                           creates a minimal non-disko sys.nix scaffold.
  --hardware-config PATH   Use an existing hardware config instead of live probing.
  --incus-host HOST        Parent host with hosts/HOST/incus.nix.
  --incus-project PROJECT  Optional Incus project for the instance.
  --incus-ipv4 ADDRESS     Optional Incus instance address and nixbot target.
  --target TARGET          Nixbot target. Defaults to HOST or --incus-ipv4.
  --proxy-jump HOST        Nixbot proxyJump. Defaults to --incus-host for Incus.
  --root PATH              Install root mountpoint. Default: /mnt
  --boot-mode efi|bios     Physical boot layout. Default: efi
  --esp-size SIZE          EFI system partition size. Default: 1G
  --boot-size SIZE         BIOS /boot partition size. Default: 1G
  --swap-size-mib MIB      Add @swap and /swap/swap0 of this size. Default: 0
  --wipe-disks             Required for install. Confirms destructive disko run.
  --dry-run                For live-install, evaluate and print install commands.
  --yes                    Skip all confirmations.
  --force                  Skip overwrite/delete/create confirmations.
  --yes-create-host        Skip confirmation for creating a new host.
  --keep-tmp               Keep tmp/host-manager.* for debugging.
  --help                   Show this help.

The script runs normally as your user and uses sudo only for live hardware
generation, disko, and nixos-install.
EOF
}

die() {
	echo "Error: $*" >&2
	exit 1
}

warn() {
	echo "warning: $*" >&2
}

info() {
	echo "$*" >&2
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	ACTION=""
	HOST=""
	HOST_SYSTEM="none"
	DISK_DEVICE=""
	HARDWARE_CONFIG=""
	INCUS_HOST=""
	INCUS_PROJECT=""
	INCUS_IPV4=""
	NIXBOT_TARGET=""
	PROXY_JUMP=""
	ROOT_MOUNT="/mnt"
	BOOT_MODE="efi"
	ESP_SIZE="1G"
	BOOT_SIZE="1G"
	SWAP_SIZE_MIB="0"
	WIPE_DISKS="0"
	DRY_RUN="0"
	YES="0"
	FORCE="0"
	YES_CREATE_HOST="0"
	KEEP_TMP="0"

	RUN_DIR=""
	GENERATED_HW_FILE=""
	EXTRACTED_HW_FILE=""
	GENERATED_SYS_FILE=""
	HOST_DIR=""
	HOSTS_DEFAULT_FILE="${REPO_ROOT}/hosts/default.nix"
	NIXBOT_FILE="${REPO_ROOT}/hosts/nixbot.nix"
	SECRETS_FILE="${REPO_ROOT}/data/secrets/default.nix"
	MACHINE_SECRET_DIR="${REPO_ROOT}/data/secrets/machine"

	BOOT_PART_UUID=""
	BIOS_PART_UUID=""
	ROOT_PART_UUID=""
	LUKS_UUID=""
	LUKS_NAME=""
}

ensure_runtime_shell() {
	local runtime_shell_flag="${HOST_MANAGER_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#age
		nixpkgs#alejandra
		nixpkgs#coreutils
		nixpkgs#disko
		nixpkgs#gawk
		nixpkgs#gnused
		nixpkgs#jq
		nixpkgs#nixos-install-tools
	)

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env HOST_MANAGER_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

resolve_path() {
	local path="$1"

	if [[ "$path" = /* ]]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$REPO_ROOT" "$path"
	fi
}

parse_args() {
	[[ $# -gt 0 ]] || {
		usage
		exit 1
	}

	case "$1" in
	generate | live-install | delete)
		ACTION="$1"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		usage
		die "Unknown action: $1"
		;;
	esac

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--host)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HOST="$2"
			shift 2
			;;
		--host=*)
			HOST="${1#--host=}"
			shift
			;;
		--system)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HOST_SYSTEM="$2"
			shift 2
			;;
		--system=*)
			HOST_SYSTEM="${1#--system=}"
			shift
			;;
		--disk)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			DISK_DEVICE="$2"
			shift 2
			;;
		--disk=*)
			DISK_DEVICE="${1#--disk=}"
			shift
			;;
		--hardware-config)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HARDWARE_CONFIG="$(resolve_path "$2")"
			shift 2
			;;
		--hardware-config=*)
			HARDWARE_CONFIG="$(resolve_path "${1#--hardware-config=}")"
			shift
			;;
		--incus-host)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			INCUS_HOST="$2"
			shift 2
			;;
		--incus-host=*)
			INCUS_HOST="${1#--incus-host=}"
			shift
			;;
		--incus-project)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			INCUS_PROJECT="$2"
			shift 2
			;;
		--incus-project=*)
			INCUS_PROJECT="${1#--incus-project=}"
			shift
			;;
		--incus-ipv4)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			INCUS_IPV4="$2"
			shift 2
			;;
		--incus-ipv4=*)
			INCUS_IPV4="${1#*=}"
			shift
			;;
		--target)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			NIXBOT_TARGET="$2"
			shift 2
			;;
		--target=*)
			NIXBOT_TARGET="${1#--target=}"
			shift
			;;
		--proxy-jump)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			PROXY_JUMP="$2"
			shift 2
			;;
		--proxy-jump=*)
			PROXY_JUMP="${1#--proxy-jump=}"
			shift
			;;
		--root)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			ROOT_MOUNT="$2"
			shift 2
			;;
		--root=*)
			ROOT_MOUNT="${1#--root=}"
			shift
			;;
		--boot-mode)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			BOOT_MODE="$2"
			shift 2
			;;
		--boot-mode=*)
			BOOT_MODE="${1#--boot-mode=}"
			shift
			;;
		--esp-size)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			ESP_SIZE="$2"
			shift 2
			;;
		--esp-size=*)
			ESP_SIZE="${1#--esp-size=}"
			shift
			;;
		--boot-size)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			BOOT_SIZE="$2"
			shift 2
			;;
		--boot-size=*)
			BOOT_SIZE="${1#--boot-size=}"
			shift
			;;
		--swap-size-mib)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			SWAP_SIZE_MIB="$2"
			shift 2
			;;
		--swap-size-mib=*)
			SWAP_SIZE_MIB="${1#--swap-size-mib=}"
			shift
			;;
		--wipe-disks)
			WIPE_DISKS="1"
			shift
			;;
		--dry-run)
			DRY_RUN="1"
			shift
			;;
		--yes)
			YES="1"
			shift
			;;
		--force)
			FORCE="1"
			shift
			;;
		--yes-create-host)
			YES_CREATE_HOST="1"
			shift
			;;
		--keep-tmp)
			KEEP_TMP="1"
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			;;
		esac
	done
}

validate_common() {
	[[ -n "$HOST" ]] || die "Missing required --host."
	[[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "--host must use letters, numbers, and hyphens."
	[[ "$HOST_SYSTEM" == "none" || "$HOST_SYSTEM" == "live" || "$HOST_SYSTEM" == "incus" ]] || die "--system must be one of: none, live, incus."
	[[ "$BOOT_MODE" == "efi" || "$BOOT_MODE" == "uefi" || "$BOOT_MODE" == "bios" ]] || die "--boot-mode must be efi or bios."
	[[ "$SWAP_SIZE_MIB" =~ ^[0-9]+$ ]] || die "--swap-size-mib must be a non-negative integer."
	[[ -z "$HARDWARE_CONFIG" || -f "$HARDWARE_CONFIG" ]] || die "Hardware config not found: $HARDWARE_CONFIG"
	HOST_DIR="${REPO_ROOT}/hosts/${HOST}"
	infer_disk_device
}

validate_args() {
	validate_common

	case "$ACTION" in
	generate)
		if [[ "$HOST_SYSTEM" == "incus" ]]; then
			[[ -n "$INCUS_HOST" ]] || die "--system=incus requires --incus-host HOST."
			[[ -d "${REPO_ROOT}/hosts/${INCUS_HOST}" ]] || die "Incus host not found: ${INCUS_HOST}"
			[[ -f "${REPO_ROOT}/hosts/${INCUS_HOST}/incus.nix" ]] || die "Incus host has no incus.nix: ${INCUS_HOST}"
		elif [[ "$HOST_SYSTEM" == "live" || -n "$HARDWARE_CONFIG" ]]; then
			[[ -n "$DISK_DEVICE" ]] || die "Physical generation requires --disk for the disko target."
		fi
		;;
	live-install)
		[[ "$DRY_RUN" == "1" || "$WIPE_DISKS" == "1" ]] || die "Install is destructive. Pass --wipe-disks."
		host_registered || die "Host is not registered: ${HOST}. Run generate first."
		[[ -f "${HOST_DIR}/sys.nix" ]] || die "Host has no sys.nix: ${HOST_DIR}/sys.nix"
		;;
	delete)
		if ! host_registered &&
			[[ ! -d "$HOST_DIR" ]] &&
			! has_nixbot_entry &&
			! has_machine_secret_registration &&
			! has_machine_key_files &&
			! find_incus_parent_for_host >/dev/null; then
			die "No host-related config found for: ${HOST}"
		fi
		;;
	*)
		die "Unsupported action: $ACTION"
		;;
	esac
}

infer_disk_device() {
	local sys_file="${HOST_DIR}/sys.nix"
	local inferred

	if [[ -n "$DISK_DEVICE" || ! -f "$sys_file" ]]; then
		return
	fi

	inferred="$(sed -n -E 's/^[[:space:]]*diskDevice = "([^"]+)";[[:space:]]*$/\1/p' "$sys_file" | head -n 1)"
	if [[ -n "$inferred" ]]; then
		DISK_DEVICE="$inferred"
		info "Using diskDevice from existing ${sys_file}: ${DISK_DEVICE}"
	fi
}

confirm_or_die() {
	local prompt="$1"
	local flag_hint="$2"
	local reply

	if [[ "$YES" == "1" ]]; then
		return
	fi

	if [[ "$FORCE" == "1" && "$flag_hint" == *"--force"* ]]; then
		return
	fi

	if [[ ! -t 0 ]]; then
		die "${prompt} Re-run with ${flag_hint} to skip confirmation."
	fi

	read -r -p "${prompt} [y/N] " reply
	case "$reply" in
	y | Y | yes | YES | Yes)
		return
		;;
	*)
		die "Aborted."
		;;
	esac
}

make_run_dir() {
	mkdir -p "${REPO_ROOT}/tmp"
	RUN_DIR="$(mktemp -d "${REPO_ROOT}/tmp/host-manager.XXXXXX")"
	GENERATED_HW_FILE="${RUN_DIR}/hardware-configuration.nix"
	EXTRACTED_HW_FILE="${RUN_DIR}/hardware-assignments.nix"
	GENERATED_SYS_FILE="${RUN_DIR}/sys.nix"
}

cleanup_run_dir() {
	if [[ -n "$RUN_DIR" && "$KEEP_TMP" != "1" ]]; then
		rm -rf "$RUN_DIR"
	fi
}

root_cmd() {
	local cmd="$1"
	local cmd_path
	shift

	if [[ "${EUID}" -eq 0 ]]; then
		"$cmd" "$@"
		return
	fi

	command -v sudo >/dev/null 2>&1 || die "Required command not found: sudo"
	cmd_path="$(command -v "$cmd")" || die "Required command not found: $cmd"
	sudo "$cmd_path" "$@"
}

nix_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
}

new_uuid() {
	cat /proc/sys/kernel/random/uuid
}

generate_ids() {
	BOOT_PART_UUID="$(new_uuid)"
	BIOS_PART_UUID="$(new_uuid)"
	ROOT_PART_UUID="$(new_uuid)"
	LUKS_UUID="$(new_uuid)"
	LUKS_NAME="luks-${LUKS_UUID}"
}

host_registered() {
	grep -Eq "^[[:space:]]*${HOST}[[:space:]]*=[[:space:]]*mkNixosSystem[[:space:]]*\\{" "$HOSTS_DEFAULT_FILE"
}

has_nixbot_entry() {
	grep -Eq "^[[:space:]]*${HOST}[[:space:]]*= \\{" "$NIXBOT_FILE"
}

has_machine_secret_registration() {
	grep -Eq "^[[:space:]]*${HOST}[[:space:]]*= ./machine/${HOST}\\.key\\.pub;" "$SECRETS_FILE" ||
		grep -Fq "\"data/secrets/machine/${HOST}.key.age\"" "$SECRETS_FILE"
}

has_machine_key_files() {
	[[ -e "${MACHINE_SECRET_DIR}/${HOST}.key" ||
		-e "${MACHINE_SECRET_DIR}/${HOST}.key.pub" ||
		-e "${MACHINE_SECRET_DIR}/${HOST}.key.age" ]]
}

ensure_host_absent_or_confirm() {
	if host_registered || [[ -e "$HOST_DIR" ]]; then
		info "Host already exists: ${HOST}"
		return
	fi

	if [[ "$YES_CREATE_HOST" != "1" ]]; then
		confirm_or_die "Host ${HOST} does not exist. Create it?" "--yes-create-host or --force"
	fi
}

write_physical_host_default() {
	mkdir -p "$HOST_DIR"
	cat >"${HOST_DIR}/default.nix" <<'EOF'
{...}: {
  imports = [
    ../../lib/profiles/all.nix
    ./sys.nix
  ];
}
EOF
	alejandra -q "${HOST_DIR}/default.nix"
}

write_lxc_host_default() {
	mkdir -p "$HOST_DIR"
	cat >"${HOST_DIR}/default.nix" <<'EOF'
{hostName, ...}: {
  imports = [
    ../../lib/profiles/lxc.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ./packages.nix
    ./users.nix
  ];
}
EOF
	touch "${HOST_DIR}/packages.nix" "${HOST_DIR}/users.nix"
	printf '{...}: {}\n' >"${HOST_DIR}/packages.nix"
	printf '{...}: {}\n' >"${HOST_DIR}/users.nix"
	alejandra -q "${HOST_DIR}/default.nix" "${HOST_DIR}/packages.nix" "${HOST_DIR}/users.nix"
}

register_host() {
	local entry_file="${RUN_DIR}/host-entry.nix"
	local next_hosts="${RUN_DIR}/hosts-default.nix"

	host_registered && return

	cat >"$entry_file" <<EOF
  ${HOST} = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "${HOST}";
    modules = [./${HOST}];
  };

EOF

	insert_before_final_brace "$entry_file" "$HOSTS_DEFAULT_FILE" "$next_hosts"
	mv "$next_hosts" "$HOSTS_DEFAULT_FILE"
	alejandra -q "$HOSTS_DEFAULT_FILE"
}

insert_before_final_brace() {
	local entry_file="$1"
	local target_file="$2"
	local output_file="$3"

	awk '
		FNR == NR {
			entry = entry $0 ORS
			next
		}

		/^}$/ && !inserted {
			printf "%s", entry
			inserted = 1
		}

		{
			print
		}

		END {
			if (!inserted) {
				exit 1
			}
		}
	' "$entry_file" "$target_file" >"$output_file" || die "Could not update ${target_file}."
}

ensure_machine_age_identity() {
	local tmp_key_file="${RUN_DIR}/${HOST}.key"
	local pub_file="${MACHINE_SECRET_DIR}/${HOST}.key.pub"
	local age_file="${MACHINE_SECRET_DIR}/${HOST}.key.age"
	local public_line
	local recipients_json
	local -a recipients=()
	local -a age_args=()
	local recipient

	mkdir -p "$MACHINE_SECRET_DIR"
	register_machine_secret

	if [[ -f "$pub_file" && -f "$age_file" ]]; then
		info "Machine age identity already exists: data/secrets/machine/${HOST}.key.age"
		return
	fi

	if [[ -e "${MACHINE_SECRET_DIR}/${HOST}.key" || -e "$pub_file" || -e "$age_file" ]]; then
		die "Partial machine identity exists for ${HOST}; inspect data/secrets/machine/${HOST}.key* before continuing."
	fi

	public_line="$(age-keygen -o "$tmp_key_file" 2>&1 | awk -F': ' '/^Public key:/ {print $2}')"
	[[ -n "$public_line" ]] || die "age-keygen did not print a public key."
	printf '%s\n' "$public_line" >"$pub_file"

	recipients_json="$(nix eval --json --file "$SECRETS_FILE")"
	mapfile -t recipients < <(jq -r --arg path "data/secrets/machine/${HOST}.key.age" '.[$path].publicKeys[]? // empty' <<<"$recipients_json")
	[[ "${#recipients[@]}" -gt 0 ]] || die "No recipients configured for data/secrets/machine/${HOST}.key.age"

	for recipient in "${recipients[@]}"; do
		age_args+=(-r "$recipient")
	done

	age "${age_args[@]}" -o "$age_file" "$tmp_key_file"
	rm -f -- "$tmp_key_file"
	info "Created machine age identity: data/secrets/machine/${HOST}.key.age"
}

register_machine_secret() {
	local next_file="${RUN_DIR}/secrets-default.nix"

	if ! grep -Eq "^[[:space:]]*${HOST}[[:space:]]*= ./machine/${HOST}\\.key\\.pub;" "$SECRETS_FILE"; then
		awk -v host="$HOST" '
			{
				if ($0 ~ /^  machineKeyFiles = \{/) {
					in_keys = 1
				}
				if (in_keys && $0 ~ /^  \};/) {
					printf "    %s = ./machine/%s.key.pub;\n", host, host
					in_keys = 0
				}
				print
			}
		' "$SECRETS_FILE" >"$next_file"
		mv "$next_file" "$SECRETS_FILE"
	fi

	if ! grep -Fq "\"data/secrets/machine/${HOST}.key.age\"" "$SECRETS_FILE"; then
		awk -v host="$HOST" '
			{
				print
				if ($0 ~ /^    # Machines$/) {
					printf "    \"data/secrets/machine/%s.key.age\".publicKeys = adminsWithNixbot;\n", host
				}
			}
		' "$SECRETS_FILE" >"$next_file"
		mv "$next_file" "$SECRETS_FILE"
	fi

	alejandra -q "$SECRETS_FILE"
}

ensure_nixbot_entry() {
	local target="$NIXBOT_TARGET"
	local proxy_jump="$PROXY_JUMP"
	local entry_file="${RUN_DIR}/nixbot-entry.nix"
	local next_file="${RUN_DIR}/nixbot.nix"

	has_nixbot_entry && return

	if [[ -z "$target" ]]; then
		if [[ "$HOST_SYSTEM" == "incus" && -n "$INCUS_IPV4" ]]; then
			target="$INCUS_IPV4"
		else
			target="$HOST"
		fi
	fi

	if [[ -z "$proxy_jump" && "$HOST_SYSTEM" == "incus" ]]; then
		proxy_jump="$INCUS_HOST"
	fi

	cat >"$entry_file" <<EOF
    ${HOST} = {
      target = "${target}";
      ageIdentityKey = "data/secrets/machine/${HOST}.key.age";
EOF
	if [[ -n "$proxy_jump" ]]; then
		cat >>"$entry_file" <<EOF
      proxyJump = "${proxy_jump}";
EOF
	fi
	if [[ -n "$INCUS_HOST" ]]; then
		cat >>"$entry_file" <<EOF
      parent = "${INCUS_HOST}";
EOF
	fi
	cat >>"$entry_file" <<'EOF'
    };
EOF

	insert_into_attrset "$entry_file" "$NIXBOT_FILE" "$next_file" '^  hosts = [{]$' '^  [}];$'
	mv "$next_file" "$NIXBOT_FILE"
	alejandra -q "$NIXBOT_FILE"
}

insert_into_attrset() {
	local entry_file="$1"
	local target_file="$2"
	local output_file="$3"
	local start_pattern="$4"
	local end_pattern="$5"

	awk -v start="$start_pattern" -v end="$end_pattern" '
		FNR == NR {
			entry = entry $0 ORS
			next
		}

		$0 ~ start {
			in_target = 1
			print
			next
		}

		in_target && $0 ~ end && !inserted {
			printf "%s", entry
			inserted = 1
			in_target = 0
		}

		{
			print
		}

		END {
			if (!inserted) {
				exit 1
			}
		}
	' "$entry_file" "$target_file" >"$output_file" || die "Could not update ${target_file}."
}

generate_hardware_config() {
	if [[ -n "$HARDWARE_CONFIG" ]]; then
		cp "$HARDWARE_CONFIG" "$GENERATED_HW_FILE"
		info "Using hardware config: $HARDWARE_CONFIG"
		return
	fi

	if [[ "$HOST_SYSTEM" != "live" ]]; then
		: >"$GENERATED_HW_FILE"
		return
	fi

	info "Generating hardware config with nixos-generate-config --show-hardware-config"
	root_cmd nixos-generate-config --show-hardware-config >"$GENERATED_HW_FILE"
}

extract_hardware_assignments() {
	awk '
	function wanted(line) {
		return line ~ /^  boot\.initrd\.availableKernelModules =/ ||
			line ~ /^  boot\.initrd\.kernelModules =/ ||
			line ~ /^  boot\.kernelModules =/ ||
			line ~ /^  boot\.extraModulePackages =/ ||
			line ~ /^  nixpkgs\.hostPlatform =/ ||
			line ~ /^  hardware\.cpu\.[^.]+\.updateMicrocode =/
	}

	wanted($0) {
		capture = 1
	}

	capture {
		print
		if ($0 ~ /;[[:space:]]*($|#)/) {
			capture = 0
		}
	}
	' "$GENERATED_HW_FILE" >"$EXTRACTED_HW_FILE"
}

print_boot_config() {
	if [[ "$BOOT_MODE" == "efi" || "$BOOT_MODE" == "uefi" ]]; then
		cat <<EOF
    boot = config.diskoLib.mkEfiBoot {
      size = "$(nix_escape "$ESP_SIZE")";
      partUuid = "$(nix_escape "$BOOT_PART_UUID")";
    };
EOF
	else
		cat <<EOF
    boot = config.diskoLib.mkBiosBoot {
      biosBoot = {
        partUuid = "$(nix_escape "$BIOS_PART_UUID")";
      };
      boot = config.diskoLib.mkExt4Boot {
        size = "$(nix_escape "$BOOT_SIZE")";
        partUuid = "$(nix_escape "$BOOT_PART_UUID")";
      };
    };
EOF
	fi
}

print_subvolumes() {
	cat <<EOF
      subvolumes = {
        "@" = {
          mountpoint = "/";
          mountOptions = ["compress=zstd"];
        };
        "@home" = {
          mountpoint = "/home";
          mountOptions = ["compress=zstd"];
        };
EOF

	if [[ "$SWAP_SIZE_MIB" != "0" ]]; then
		cat <<EOF
        "@swap".mountpoint = "/swap";
EOF
	fi

	cat <<EOF
      };
EOF
}

print_swap_devices() {
	if [[ "$SWAP_SIZE_MIB" == "0" ]]; then
		cat <<EOF
  swapDevices = [];
EOF
	else
		cat <<EOF
  swapDevices = [
    {
      device = "/swap/swap0";
      size = ${SWAP_SIZE_MIB};
    }
  ];
EOF
	fi
}

write_sys_nix() {
	local disko_import

	mkdir -p "$HOST_DIR"
	disko_import="$(realpath --relative-to "$HOST_DIR" "${REPO_ROOT}/lib/disko")"

	{
		cat <<EOF
# Hardware and install-storage config. Generated by scripts/host-manager.sh.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ${disko_import}
  ];

  disko.devices.disk.main = config.diskoLib.mkMain {
    diskDevice = "$(nix_escape "$DISK_DEVICE")";
EOF
		print_boot_config
		cat <<EOF
    root = config.diskoLib.mkLuksBtrfs {
      size = "100%";
      name = "$(nix_escape "$LUKS_NAME")";
      luksUuid = "$(nix_escape "$LUKS_UUID")";
      partUuid = "$(nix_escape "$ROOT_PART_UUID")";
EOF
		print_subvolumes
		cat <<EOF
    };
  };

EOF
		if [[ -s "$EXTRACTED_HW_FILE" ]]; then
			cat "$EXTRACTED_HW_FILE"
			printf '\n\n'
		else
			cat <<EOF
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

EOF
		fi
		print_swap_devices
		cat <<EOF
}
EOF
	} >"$GENERATED_SYS_FILE"

	alejandra -q "$GENERATED_SYS_FILE"
}

write_minimal_sys_nix() {
	mkdir -p "$HOST_DIR"
	cat >"$GENERATED_SYS_FILE" <<'EOF'
# Minimal hardware scaffold. Regenerate with --system=live or --disk to add disko.
{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
EOF
	alejandra -q "$GENERATED_SYS_FILE"
}

install_sys_nix() {
	local target_file="${HOST_DIR}/sys.nix"

	if [[ -e "$target_file" && ! -s "$GENERATED_SYS_FILE" ]]; then
		return
	fi

	if [[ -e "$target_file" ]]; then
		if cmp -s "$GENERATED_SYS_FILE" "$target_file"; then
			info "Generated sys.nix matches existing file: $target_file"
			return
		fi
		confirm_or_die "Generated sys.nix differs from existing ${target_file}. Overwrite it?" "--force"
	fi

	cp "$GENERATED_SYS_FILE" "$target_file"
	alejandra -q "$target_file"
	info "Generated sys.nix: $target_file"
}

ensure_incus_instance() {
	local parent_file="${REPO_ROOT}/hosts/${INCUS_HOST}/incus.nix"
	local entry_file="${RUN_DIR}/incus-entry.nix"
	local next_file="${RUN_DIR}/incus.nix"

	if grep -Eq "^[[:space:]]*${HOST}[[:space:]]*=" "$parent_file"; then
		info "Incus instance already exists on ${INCUS_HOST}: ${HOST}"
		return
	fi

	cat >"$entry_file" <<EOF
      ${HOST} = {
EOF
	if [[ -n "$INCUS_PROJECT" ]]; then
		cat >>"$entry_file" <<EOF
        project = "${INCUS_PROJECT}";
EOF
	fi
	if [[ -n "$INCUS_IPV4" ]]; then
		cat >>"$entry_file" <<EOF
        ipv4Address = "${INCUS_IPV4}";
EOF
	fi
	cat >>"$entry_file" <<EOF
        config = {
          "security.privileged" = "false";
        };
        devices = {
          state = {
            source = "${HOST}";
            path = "/var/lib";
            removalPolicy = "delete";
          };
        };
      };
EOF

	insert_into_attrset "$entry_file" "$parent_file" "$next_file" '^[[:space:]]*instances = [{]$' '^    [}];$'
	mv "$next_file" "$parent_file"
	alejandra -q "$parent_file"
	info "Added Incus instance ${HOST} to hosts/${INCUS_HOST}/incus.nix"
}

run_generate() {
	ensure_host_absent_or_confirm

	if [[ "$HOST_SYSTEM" == "incus" ]]; then
		if [[ ! -e "${HOST_DIR}/default.nix" ]]; then
			write_lxc_host_default
		fi
		register_host
		ensure_machine_age_identity
		ensure_nixbot_entry
		ensure_incus_instance
		return
	fi

	if [[ ! -e "${HOST_DIR}/default.nix" ]]; then
		write_physical_host_default
	fi
	register_host
	ensure_machine_age_identity
	ensure_nixbot_entry
	if [[ -n "$DISK_DEVICE" ]]; then
		generate_ids
		generate_hardware_config
		extract_hardware_assignments
		write_sys_nix
	else
		write_minimal_sys_nix
	fi
	install_sys_nix
}

run_install() {
	if [[ "$BOOT_MODE" == "efi" || "$BOOT_MODE" == "uefi" ]]; then
		[[ -d /sys/firmware/efi/efivars ]] || die "UEFI boot mode requested, but this live environment is not booted with EFI variables."
	fi

	info "Checking disko target for .#${HOST}"
	nix eval "${REPO_ROOT}#nixosConfigurations.${HOST}.config.disko.devices.disk.main.device" --raw >/dev/null

	if [[ "$DRY_RUN" == "1" ]]; then
		info "Dry run; would run:"
		print_install_commands >&2
		return
	fi

	confirm_or_die "Run disko for ${HOST}? This will destroy, format, and mount the disks declared by the host disko config." "--yes"
	info "Running disko for .#${HOST}; only disks declared by that host disko config are formatted."
	root_cmd disko --mode destroy,format,mount --flake "${REPO_ROOT}#${HOST}" --root-mountpoint "$ROOT_MOUNT" --yes-wipe-all-disks

	confirm_or_die "Run nixos-install for ${HOST} into ${ROOT_MOUNT}?" "--yes"
	info "Running nixos-install for .#${HOST}"
	root_cmd nixos-install --flake "${REPO_ROOT}#${HOST}" --root "$ROOT_MOUNT" --no-root-passwd
}

print_install_commands() {
	cat <<EOF
disko --mode destroy,format,mount --flake ${REPO_ROOT}#${HOST} --root-mountpoint ${ROOT_MOUNT} --yes-wipe-all-disks
nixos-install --flake ${REPO_ROOT}#${HOST} --root ${ROOT_MOUNT} --no-root-passwd
EOF
}

remove_attr_block() {
	local attr_name="$1"
	local input_file="$2"
	local output_file="$3"

	awk -v name="$attr_name" '
		function delta(line, i, c, d) {
			d = 0
			for (i = 1; i <= length(line); i++) {
				c = substr(line, i, 1)
				if (c == "{") d++
				if (c == "}") d--
			}
			return d
		}

		!skipping && $0 ~ "^[[:space:]]*" name "[[:space:]]*=" {
			skipping = 1
			depth = delta($0)
			if (depth <= 0 && $0 ~ /;[[:space:]]*$/) {
				skipping = 0
			}
			next
		}

		skipping {
			depth += delta($0)
			if (depth <= 0 && $0 ~ /;[[:space:]]*$/) {
				skipping = 0
			}
			next
		}

		{
			print
		}
	' "$input_file" >"$output_file"
}

remove_line_containing() {
	local input_file="$1"
	local output_file="$2"
	local needle="$3"

	awk -v needle="$needle" 'index($0, needle) == 0 { print }' "$input_file" >"$output_file"
}

find_incus_parent_for_host() {
	local file

	for file in "${REPO_ROOT}"/hosts/*/incus.nix; do
		[[ -f "$file" ]] || continue
		if grep -Eq "^[[:space:]]*${HOST}[[:space:]]*=" "$file"; then
			basename "$(dirname "$file")"
			return 0
		fi
	done
	return 1
}

delete_host() {
	local next_file
	local incus_parent
	local incus_file

	confirm_or_die "Delete host ${HOST} from repo config and machine secrets?" "--force"

	if host_registered; then
		next_file="${RUN_DIR}/hosts-default.nix"
		remove_attr_block "$HOST" "$HOSTS_DEFAULT_FILE" "$next_file"
		mv "$next_file" "$HOSTS_DEFAULT_FILE"
		alejandra -q "$HOSTS_DEFAULT_FILE"
	fi

	if has_nixbot_entry; then
		next_file="${RUN_DIR}/nixbot.nix"
		remove_attr_block "$HOST" "$NIXBOT_FILE" "$next_file"
		mv "$next_file" "$NIXBOT_FILE"
		alejandra -q "$NIXBOT_FILE"
	fi

	if has_machine_secret_registration; then
		next_file="${RUN_DIR}/secrets-default.nix"
		remove_line_containing "$SECRETS_FILE" "$next_file" "${HOST} = ./machine/${HOST}.key.pub;"
		mv "$next_file" "$SECRETS_FILE"
		remove_line_containing "$SECRETS_FILE" "$next_file" "\"data/secrets/machine/${HOST}.key.age\""
		mv "$next_file" "$SECRETS_FILE"
		alejandra -q "$SECRETS_FILE"
	fi

	incus_parent="${INCUS_HOST:-}"
	if [[ -z "$incus_parent" ]]; then
		incus_parent="$(find_incus_parent_for_host || true)"
	fi
	if [[ -n "$incus_parent" ]]; then
		incus_file="${REPO_ROOT}/hosts/${incus_parent}/incus.nix"
		next_file="${RUN_DIR}/incus.nix"
		remove_attr_block "$HOST" "$incus_file" "$next_file"
		mv "$next_file" "$incus_file"
		alejandra -q "$incus_file"
	fi

	rm -rf "$HOST_DIR"
	rm -f -- \
		"${MACHINE_SECRET_DIR}/${HOST}.key" \
		"${MACHINE_SECRET_DIR}/${HOST}.key.pub" \
		"${MACHINE_SECRET_DIR}/${HOST}.key.age"
	info "Deleted host: ${HOST}"
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	make_run_dir
	trap cleanup_run_dir EXIT
	validate_args

	case "$ACTION" in
	generate) run_generate ;;
	live-install) run_install ;;
	delete) delete_host ;;
	esac
}

main "$@"

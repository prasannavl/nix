#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/host-manager.sh build HOST|--host=HOST --store PATH
  scripts/host-manager.sh generate HOST|--host=HOST [--system=none|live|incus] [options]
  scripts/host-manager.sh live-install HOST|--host=HOST --wipe-disks [options]
  scripts/host-manager.sh delete HOST|--host=HOST [--force|--yes]
  scripts/host-manager.sh ssh HOST|--host=HOST [-- ssh-args...]
  scripts/host-manager.sh reboot HOST|--host=HOST|--hosts=SELECTORS [--jobs N] [--dry-run] [--yes]
  scripts/host-manager.sh gc HOST|--host=HOST|--hosts=SELECTORS [--jobs N] [--delete-older-than AGE|--all] [--dry-run] [--yes]
  scripts/host-manager.sh clean:deploy HOST|--host=HOST|--hosts=SELECTORS [--jobs N] [--dry-run] [--force-held] [--yes]
  scripts/host-manager.sh clean:podman HOST|--host=HOST|--hosts=SELECTORS [--jobs N] [--dry-run] [--force-held] [--yes]
  scripts/host-manager.sh clean:nixbot HOST|--host=HOST|--hosts=SELECTORS [--jobs N] [--dry-run] [--force-held] [--yes]
  scripts/host-manager.sh logs HOST|--host=HOST [--service SERVICE] [--since WHEN] [--lines N] [--follow]
  scripts/host-manager.sh service start|stop|restart|status|logs SERVICE [--stack STACK|--host HOST] [--user USER] [--since WHEN] [--lines N] [--follow]

The flake package also provides an equivalent host-manager binary.

Examples:
  scripts/host-manager.sh generate pvl-a1 --system=live \
    --disk /dev/disk/by-id/nvme-Lexar_SSD_ARES_2TB_QEC053R000846P2222 \
    --swap-size-mib 65536

  scripts/host-manager.sh build pvl-a1 --store /media/live-usb/nix-cache

  scripts/host-manager.sh live-install pvl-a1 --store /media/live-usb/nix-cache --wipe-disks

  scripts/host-manager.sh generate pvl-new --disk /dev/disk/by-id/nvme-...

  scripts/host-manager.sh generate pvl-guest --system=incus --incus-host pvl-x2 \
    --incus-ipv4 10.10.20.50

Actions:
  build                    Build a host system and copy the closure, flake
                           inputs, and host-manager runtime deps to --store.
  generate                 Create or update repo host config.
  live-install             Run live disko and nixos-install for an existing host.
  delete                   Remove host config, nixbot entry, age machine keys,
                           secret registration, and matching Incus instance
                           declaration.
  ssh                      Open SSH to a host using the repo host inventory.
  reboot                   Reboot the addressed host with systemctl reboot.
  gc                       Run Nix garbage collection on a host.
  clean:deploy             Clear nixbot and Podman deploy-related locks and
                           unused anonymous Podman volumes on a host.
  clean:podman             Clear Podman compose lifecycle locks and unused
                           anonymous Podman volumes on a host.
  clean:nixbot             Clear nixbot-related lock directories on a host.
  logs                     Show the host journal for a host, or one service on
                           that host with --service.
  service start|stop|restart|status|logs
                           Control, inspect, or show logs for every registry
                           instance of a service, or only --host HOST.

Options:
  --host HOST              One host. Equivalent to positional HOST for
                           host-targeted commands.
  --hosts SELECTORS        Nixbot-style host selectors for reboot, gc, and
                           clean:*: comma/space lists, globs, -exclusions, all,
                           and group: selectors. Example:
                           --hosts='group:abird-dev,-abird-dev-ci'.
  --jobs N                 Parallel host jobs for multi-host maintenance.
                           Default: 8.
  --stack STACK            Optional stack key from lib/stacks.
  --system SYSTEM          Generate target type: none, live, or incus.
                           Default: none.
  --disk PATH              Stable target disk path. Adds physical disko sys.nix.
                           Without --system=live/--hardware-config, omitting this
                           creates a minimal non-disko sys.nix scaffold.
  --hardware-config PATH   Use an existing hardware config instead of live probing.
  --incus-host HOST        Parent host with hosts/HOST/incus.nix.
  --incus-project PROJECT  Optional Incus project for the instance.
  --incus-ipv4 ADDRESS     Incus instance address and nixbot target.
                           Required for --system=incus.
  --target TARGET          Nixbot target. Defaults to HOST or --incus-ipv4.
  --proxy-jump HOST        Nixbot proxyJump. Defaults to --incus-host for Incus.
  --root PATH              Install root mountpoint. Default: /mnt
  --store PATH             Local file binary cache for build/live-install.
  --boot-mode efi|uefi|bios
                           Physical boot layout. Default: efi
  --esp-size SIZE          EFI system partition size. Default: 1G
  --boot-size SIZE         BIOS /boot partition size. Default: 1G
  --swap-size-mib MIB      Add @swap and /swap/swap0 of this size. Default: 0
  --wipe-disks             Required for install. Confirms destructive disko run.
  --dry-run                For live-install, evaluate and print install commands.
                           For remote maintenance commands, audit/print without
                           mutating the host.
  --yes                    Skip all confirmations.
  --force                  Skip overwrite/delete/create confirmations.
  --force-held             For remote lock cleanup, also remove lock paths that
                           still have open file-descriptor holders.
  --delete-older-than AGE  Nix GC deletion age. Default: 7d.
  --all                    For gc, run nix-collect-garbage -d.
  --user USER              SSH user for host operations; systemd-user account
                           for service operations.
  --service SERVICE        For logs HOST, show only this service on the host.
  --since WHEN             journalctl --since value for logs.
  --lines N                journalctl --lines value for logs. Default: 200.
  --follow                 Follow logs.
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
	REPO_ROOT="$(find_repo_root)"
	ACTION=""
	HOST=""
	HOSTS_RAW=""
	HOST_STACK=""
	HOST_SYSTEM="none"
	DISK_DEVICE=""
	HARDWARE_CONFIG=""
	INCUS_HOST=""
	INCUS_PROJECT=""
	INCUS_IPV4=""
	NIXBOT_TARGET=""
	PROXY_JUMP=""
	ROOT_MOUNT="/mnt"
	STORE_DIR=""
	BOOT_MODE="efi"
	ESP_SIZE="1G"
	BOOT_SIZE="1G"
	SWAP_SIZE_MIB="0"
	WIPE_DISKS="0"
	DRY_RUN="0"
	YES="0"
	FORCE="0"
	FORCE_HELD="0"
	YES_CREATE_HOST="0"
	KEEP_TMP="0"
	DELETE_OLDER_THAN="7d"
	GC_ALL="0"
	HOST_FROM_FLAG="0"
	HOSTS_FROM_FLAG="0"
	HOST_JOBS="8"
	OP_USER="${HOST_MANAGER_USER:-$(id -un 2>/dev/null || printf root)}"
	OP_USER_EXPLICIT="0"
	if [[ -n "${HOST_MANAGER_USER:-}" ]]; then
		OP_USER_EXPLICIT="1"
	fi
	SERVICE_NAME=""
	LOG_USER=""
	LOG_SINCE=""
	LOG_LINES="200"
	LOG_FOLLOW="0"
	SSH_EXTRA_ARGS=()

	RUN_DIR=""
	SECRET_RUN_DIR=""
	STAGE_DIR=""
	MUTATION_LOCK_DIR=""
	STORE_LOCK_DIR=""
	GENERATED_HW_FILE=""
	EXTRACTED_HW_FILE=""
	GENERATED_SYS_FILE=""
	HOST_DIR=""
	HOSTS_DEFAULT_FILE="${REPO_ROOT}/hosts/default.nix"
	HOST_MANAGER_POLICY_FILE="${REPO_ROOT}/pkgs/tools/host-manager/policy.nix"
	NIXBOT_FILE="${REPO_ROOT}/hosts/nixbot.nix"
	NIXBOT_OVERRIDE_FILE="${NIXBOT_FILE%.nix}.override.nix"
	SECRETS_FILE="${REPO_ROOT}/data/secrets/default.nix"
	MACHINE_SECRET_DIR="${REPO_ROOT}/data/secrets/globals/machine"
	NIXBOT_CONFIG_JSON=""
	NIXBOT_HOSTS_JSON=""
	NIXBOT_GROUPS_JSON=""
	REMOTE_SSH_CONFIG=""
	REMOTE_SSH_TARGET=""
	REMOTE_SSH_ARGS=()

	BOOT_PART_UUID=""
	BIOS_PART_UUID=""
	ROOT_PART_UUID=""
	LUKS_UUID=""
	LUKS_NAME=""
	STAGED_TARGETS=()
}

find_repo_root() {
	local start

	if [[ -n "${HOST_MANAGER_REPO_ROOT:-}" ]]; then
		start="$HOST_MANAGER_REPO_ROOT"
		find_repo_root_from "$start" || die "HOST_MANAGER_REPO_ROOT is not inside this repo: ${HOST_MANAGER_REPO_ROOT}"
		return
	fi

	start="$(pwd -P)"
	if find_repo_root_from "$start"; then
		return
	fi

	start="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
	find_repo_root_from "$start" || die "Could not find repo root. Run from the repo or set HOST_MANAGER_REPO_ROOT."
}

find_repo_root_from() {
	local dir="$1"

	dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
	while [[ "$dir" != "/" ]]; do
		if [[ -f "${dir}/flake.nix" && -f "${dir}/pkgs/manifest.nix" && -d "${dir}/hosts" ]]; then
			printf '%s\n' "$dir"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	return 1
}

ensure_runtime_shell() {
	local runtime_shell_flag="${HOST_MANAGER_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local store_dir
	local -a runtime_pkgs

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(find_repo_root)"
	store_dir="$(preparse_store_arg "$flake_path" "$@")"
	mapfile -t runtime_pkgs < <(runtime_packages)

	if [[ -n "$store_dir" && -f "${store_dir}/nix-cache-info" ]]; then
		exec nix --quiet --no-warn-dirty shell \
			--option substituters "$(store_url "$store_dir")" \
			--option require-sigs false \
			--inputs-from "${flake_path}" \
			"${runtime_pkgs[@]}" \
			-c env HOST_MANAGER_IN_NIX_SHELL=1 bash "${script_path}" "$@"
	fi

	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_pkgs[@]}" -c env HOST_MANAGER_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

# Keep in sync with runtimeInputs in pkgs/tools/host-manager/default.nix.
runtime_packages() {
	printf '%s\n' \
		nixpkgs#age \
		nixpkgs#alejandra \
		nixpkgs#coreutils \
		nixpkgs#disko \
		nixpkgs#gawk \
		nixpkgs#gnugrep \
		nixpkgs#gnused \
		nixpkgs#jq \
		nixpkgs#nix \
		nixpkgs#nixos-install-tools \
		nixpkgs#openssh
}

preparse_store_arg() {
	local root="$1"
	shift
	local arg

	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--store)
			[[ $# -ge 2 ]] || return 0
			resolve_path_from "$root" "$2"
			return
			;;
		--store=*)
			resolve_path_from "$root" "${arg#--store=}"
			return
			;;
		esac
		shift
	done
}

resolve_path_from() {
	local root="$1"
	local path="$2"

	if [[ "$path" = /* ]]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$root" "$path"
	fi
}

resolve_path() {
	local path="$1"

	if [[ "$path" = /* ]]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$REPO_ROOT" "$path"
	fi
}

store_url() {
	local store_dir="$1"

	validate_store_dir "$store_dir"
	printf 'file://%s\n' "$store_dir"
}

validate_store_dir() {
	local store_dir="$1"

	[[ -n "$store_dir" ]] || die "--store path must not be empty."
	[[ "$store_dir" != *[[:space:]]* ]] || die "--store path must not contain whitespace: $store_dir"
	[[ "$store_dir" != *[[:cntrl:]]* ]] || die "--store path must not contain control characters."
	[[ "$store_dir" != *[?#%]* ]] || die "--store path must not contain URL-reserved characters (?, #, %): $store_dir"
}

store_nix_config() {
	local store_dir="$1"

	cat <<EOF
substituters = $(store_url "$store_dir")
require-sigs = false
EOF
}

parse_args() {
	local user_value

	[[ $# -gt 0 ]] || {
		usage
		exit 1
	}

	case "$1" in
	build | generate | live-install | delete | ssh | reboot | gc | logs)
		ACTION="$1"
		shift
		;;
	clean:podman)
		ACTION="podman-clean"
		shift
		;;
	clean:nixbot)
		ACTION="nixbot-clean"
		shift
		;;
	clean:deploy)
		ACTION="deploy-clean"
		shift
		;;
	service)
		shift
		[[ $# -gt 0 ]] || die "service requires an action: start, stop, restart, status, or logs"
		case "$1" in
		start | stop | restart | status | logs)
			ACTION="service-$1"
			shift
			;;
		*)
			die "service supports only: start, stop, restart, status, logs"
			;;
		esac
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

	case "$ACTION" in
	build | generate | live-install | delete | ssh | reboot | gc | podman-clean | nixbot-clean | deploy-clean | logs)
		if [[ $# -gt 0 && "$1" != --* ]]; then
			HOST="$1"
			shift
		fi
		;;
	service-start | service-stop | service-restart | service-status | service-logs)
		if [[ $# -gt 0 && "$1" != --* ]]; then
			SERVICE_NAME="$1"
			shift
		fi
		;;
	esac

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--)
			shift
			if [[ "$ACTION" == "ssh" ]]; then
				SSH_EXTRA_ARGS=("$@")
				break
			fi
			die "-- is only supported by ssh"
			;;
		--host)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HOST="$2"
			HOST_FROM_FLAG="1"
			shift 2
			;;
		--host=*)
			HOST="${1#--host=}"
			HOST_FROM_FLAG="1"
			shift
			;;
		--hosts)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HOSTS_RAW="$2"
			HOSTS_FROM_FLAG="1"
			shift 2
			;;
		--hosts=*)
			HOSTS_RAW="${1#--hosts=}"
			HOSTS_FROM_FLAG="1"
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
		--stack)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HOST_STACK="$2"
			shift 2
			;;
		--stack=*)
			HOST_STACK="${1#--stack=}"
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
			INCUS_IPV4="${1#--incus-ipv4=}"
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
		--store)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			STORE_DIR="$(resolve_path "$2")"
			shift 2
			;;
		--store=*)
			STORE_DIR="$(resolve_path "${1#--store=}")"
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
		--delete-older-than)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			DELETE_OLDER_THAN="$2"
			shift 2
			;;
		--delete-older-than=*)
			DELETE_OLDER_THAN="${1#--delete-older-than=}"
			shift
			;;
		--all)
			if [[ "$ACTION" == "gc" ]]; then
				GC_ALL="1"
			else
				die "--all is only supported by gc."
			fi
			shift
			;;
		--jobs)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			HOST_JOBS="$2"
			shift 2
			;;
		--jobs=*)
			HOST_JOBS="${1#--jobs=}"
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
		--force-held)
			FORCE_HELD="1"
			shift
			;;
		--user)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			if [[ "$ACTION" == service-* ]]; then
				LOG_USER="$2"
			else
				OP_USER="$2"
				OP_USER_EXPLICIT="1"
			fi
			shift 2
			;;
		--user=*)
			user_value="${1#--user=}"
			if [[ "$ACTION" == service-* ]]; then
				LOG_USER="$user_value"
			else
				OP_USER="$user_value"
				OP_USER_EXPLICIT="1"
			fi
			shift
			;;
		--service)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			[[ "$ACTION" == "logs" ]] || die "--service is only supported by logs HOST."
			SERVICE_NAME="$2"
			shift 2
			;;
		--service=*)
			[[ "$ACTION" == "logs" ]] || die "--service is only supported by logs HOST."
			SERVICE_NAME="${1#--service=}"
			shift
			;;
		--since)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			LOG_SINCE="$2"
			shift 2
			;;
		--since=*)
			LOG_SINCE="${1#--since=}"
			shift
			;;
		--lines)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			LOG_LINES="$2"
			shift 2
			;;
		--lines=*)
			LOG_LINES="${1#--lines=}"
			shift
			;;
		--follow | -f)
			LOG_FOLLOW="1"
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
			case "$ACTION" in
			build | generate | live-install | delete | ssh | reboot | gc | podman-clean | nixbot-clean | deploy-clean | logs)
				if [[ -z "$HOST" && "$1" != --* ]]; then
					HOST="$1"
					shift
					continue
				fi
				;;
			service-start | service-stop | service-restart | service-status | service-logs)
				if [[ -z "$SERVICE_NAME" && "$1" != --* ]]; then
					SERVICE_NAME="$1"
					shift
					continue
				fi
				;;
			esac
			die "Unknown argument: $1"
			;;
		esac
	done
}

maintenance_action_supports_all() {
	case "$ACTION" in
	reboot | gc | podman-clean | nixbot-clean | deploy-clean)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

validate_common() {
	if [[ "$HOSTS_FROM_FLAG" == "1" ]]; then
		maintenance_action_supports_all || die "--hosts is only supported by reboot, gc, and clean commands."
		[[ -z "$HOST" ]] || die "Use either HOST/--host or --hosts, not both."
		[[ -n "$HOSTS_RAW" ]] || die "--hosts cannot be empty."
	elif [[ "$ACTION" != service-* || -n "$HOST" ]]; then
		[[ -n "$HOST" ]] || die "Missing required HOST."
		if [[ "$HOST" == "all" ]]; then
			[[ "$HOST_FROM_FLAG" == "1" ]] || die "Use --hosts=all to target every nixbot inventory host."
			maintenance_action_supports_all || die "HOST=all is only supported by reboot, gc, and clean commands."
		else
			valid_host_name "$HOST" || die "HOST must start and end with a letter or number, and use only letters, numbers, and hyphens."
		fi
	fi
	[[ "$HOST_SYSTEM" == "none" || "$HOST_SYSTEM" == "live" || "$HOST_SYSTEM" == "incus" ]] || die "--system must be one of: none, live, incus."
	[[ "$BOOT_MODE" == "efi" || "$BOOT_MODE" == "uefi" || "$BOOT_MODE" == "bios" ]] || die "--boot-mode must be one of: efi, uefi, bios."
	[[ "$SWAP_SIZE_MIB" =~ ^[0-9]+$ ]] || die "--swap-size-mib must be a non-negative integer."
	[[ -z "$INCUS_IPV4" ]] || valid_ipv4 "$INCUS_IPV4" || die "--incus-ipv4 must be an IPv4 address."
	[[ -z "$INCUS_HOST" ]] || valid_host_name "$INCUS_HOST" || die "--incus-host must start and end with a letter or number, and use only letters, numbers, and hyphens."
	[[ -z "$STORE_DIR" ]] || validate_store_dir "$STORE_DIR"
	[[ -z "$HARDWARE_CONFIG" || -f "$HARDWARE_CONFIG" ]] || die "Hardware config not found: $HARDWARE_CONFIG"
	[[ "$LOG_LINES" =~ ^[0-9]+$ ]] || die "--lines must be a non-negative integer."
	[[ "$HOST_JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer."
	if [[ -n "$HOST" && "$HOST" != "all" ]]; then
		HOST_DIR="${REPO_ROOT}/hosts/${HOST}"
		infer_disk_device
	else
		HOST_DIR=""
	fi
}

valid_host_name() {
	local name="$1"

	[[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

valid_incus_instance_name() {
	local name="$1"

	[[ "$name" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

stack_exists() {
	local stack="$1"

	[[ "$(nix eval --raw --file "${REPO_ROOT}/lib/stacks/default.nix" --apply "stacks: if builtins.hasAttr \"$(nix_escape "$stack")\" stacks then \"1\" else \"0\"")" == "1" ]]
}

default_service_stack() {
	local stack

	if [[ -n "${HOST_MANAGER_SERVICE_STACK:-}" ]]; then
		printf '%s\n' "$HOST_MANAGER_SERVICE_STACK"
		return
	fi

	[[ -f "$HOST_MANAGER_POLICY_FILE" ]] || die "Host-manager policy not found: ${HOST_MANAGER_POLICY_FILE}"
	stack="$(nix eval --raw --file "$HOST_MANAGER_POLICY_FILE" --apply 'policy: policy.defaultServiceStack or ""')"
	[[ -n "$stack" ]] || die "Host-manager policy must define defaultServiceStack."
	printf '%s\n' "$stack"
}

valid_ipv4() {
	local ip="$1"
	local octet
	local -a octets

	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS=. read -r -a octets <<<"$ip"
	for octet in "${octets[@]}"; do
		((10#$octet <= 255)) || return 1
	done
}

validate_delete_incus_parent() {
	local parent_file source_file

	[[ -n "$INCUS_HOST" ]] || return 0
	parent_file="${REPO_ROOT}/hosts/${INCUS_HOST}/incus.nix"
	[[ -f "$parent_file" ]] || die "Incus host has no incus.nix: ${INCUS_HOST}"
	source_file="$(target_read_path "$parent_file")"
	grep -Eq "$(nix_attr_assignment_regex "$HOST")" "$source_file" || die "Host ${HOST} is not declared in Incus host ${INCUS_HOST}."
}

validate_args() {
	validate_common

	case "$ACTION" in
	build)
		[[ -n "$STORE_DIR" ]] || die "build requires --store PATH."
		host_registered || die "Host is not registered: ${HOST}."
		;;
	generate)
		[[ -z "$HOST_STACK" ]] || stack_exists "$HOST_STACK" || die "Stack does not exist in lib/stacks: ${HOST_STACK}"
		if [[ "$HOST_SYSTEM" == "incus" ]]; then
			[[ -n "$INCUS_HOST" ]] || die "--system=incus requires --incus-host HOST."
			[[ -n "$INCUS_IPV4" ]] || die "--system=incus requires --incus-ipv4 ADDRESS."
			valid_incus_instance_name "$HOST" || die "HOST must match Incus instance names for --system=incus: [a-z]([a-z0-9-]{0,61}[a-z0-9])?"
			[[ -d "${REPO_ROOT}/hosts/${INCUS_HOST}" ]] || die "Incus host not found: ${INCUS_HOST}"
			[[ -f "${REPO_ROOT}/hosts/${INCUS_HOST}/incus.nix" ]] || die "Incus host has no incus.nix: ${INCUS_HOST}"
		elif [[ "$HOST_SYSTEM" == "live" || -n "$HARDWARE_CONFIG" ]]; then
			[[ -n "$DISK_DEVICE" ]] || die "Physical generation requires --disk for the disko target."
		fi
		;;
	live-install)
		if [[ -n "$STORE_DIR" && ! -f "${STORE_DIR}/nix-cache-info" ]]; then
			die "--store does not look like a Nix file binary cache: ${STORE_DIR}"
		fi
		[[ "$DRY_RUN" == "1" || "$WIPE_DISKS" == "1" ]] || die "Install is destructive. Pass --wipe-disks."
		host_registered || die "Host is not registered: ${HOST}. Run generate first."
		[[ -f "${HOST_DIR}/sys.nix" ]] || die "Host has no sys.nix: ${HOST_DIR}/sys.nix"
		;;
	delete)
		validate_delete_incus_parent
		if ! host_registered &&
			[[ ! -d "$HOST_DIR" ]] &&
			! has_nixbot_entry &&
			! has_machine_secret_registration &&
			! has_machine_key_files &&
			! find_incus_parent_for_host >/dev/null; then
			die "No host-related config found for: ${HOST}"
		fi
		;;
	ssh | logs)
		nixbot_host_registered "$HOST" || die "Host is not in ${NIXBOT_FILE}: ${HOST}"
		;;
	reboot | gc | podman-clean | nixbot-clean | deploy-clean)
		if [[ "$HOSTS_FROM_FLAG" == "1" ]]; then
			resolve_maintenance_host_selectors "$HOSTS_RAW" >/dev/null
		elif [[ "$HOST" == "all" ]]; then
			nixbot_inventory_hosts >/dev/null
		else
			nixbot_host_registered "$HOST" || die "Host is not in ${NIXBOT_FILE}: ${HOST}"
		fi
		;;
	service-start | service-stop | service-restart | service-status | service-logs)
		[[ -n "$SERVICE_NAME" ]] || die "${ACTION#service-} requires a service or unit name."
		if [[ -n "$HOST" ]]; then
			nixbot_host_registered "$HOST" || die "Host is not in ${NIXBOT_FILE}: ${HOST}"
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

	# Host sys.nix files currently carry one top-level diskDevice assignment.
	inferred="$(sed -n -E 's/^[[:space:]]*diskDevice = "([^"]+)";[[:space:]]*$/\1/p' "$sys_file" | head -n 1)"
	if [[ -n "$inferred" ]]; then
		DISK_DEVICE="$inferred"
		info "Using diskDevice from existing ${sys_file}: ${DISK_DEVICE}"
	fi
	return 0
}

confirm_or_die() {
	local prompt="$1"
	local flag_hint="$2"
	local allow_force="${3:-0}"
	local reply

	if [[ "$YES" == "1" ]]; then
		return
	fi

	if [[ "$FORCE" == "1" && "$allow_force" == "1" ]]; then
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
	local secret_parent="${TMPDIR:-/tmp}"

	mkdir -p "${REPO_ROOT}/tmp"
	RUN_DIR="$(mktemp -d "${REPO_ROOT}/tmp/host-manager.XXXXXX")"
	STAGE_DIR="${RUN_DIR}/staged"
	if [[ -d /dev/shm && -w /dev/shm ]]; then
		secret_parent="/dev/shm"
	fi
	SECRET_RUN_DIR="$(umask 077 && mktemp -d "${secret_parent%/}/host-manager-secret.XXXXXX")"
	GENERATED_HW_FILE="${RUN_DIR}/hardware-configuration.nix"
	EXTRACTED_HW_FILE="${RUN_DIR}/hardware-assignments.nix"
	GENERATED_SYS_FILE="${RUN_DIR}/sys.nix"
}

target_rel_path() {
	local target="$1"

	case "$target" in
	"$REPO_ROOT"/*)
		printf '%s\n' "${target#"$REPO_ROOT"/}"
		;;
	*)
		die "Refusing to stage path outside repo: $target"
		;;
	esac
}

stage_target_path() {
	local target="$1"
	local rel

	rel="$(target_rel_path "$target")"
	printf '%s/%s\n' "$STAGE_DIR" "$rel"
}

target_read_path() {
	local target="$1"
	local staged

	staged="$(stage_target_path "$target")"
	if [[ -e "$staged" ]]; then
		printf '%s\n' "$staged"
	else
		printf '%s\n' "$target"
	fi
}

register_staged_target() {
	local target="$1"
	local existing

	for existing in "${STAGED_TARGETS[@]}"; do
		[[ "$existing" == "$target" ]] && return
	done
	STAGED_TARGETS+=("$target")
}

stage_file_for_write() {
	local target="$1"
	local staged

	staged="$(stage_target_path "$target")"
	mkdir -p "$(dirname "$staged")"
	printf '%s\n' "$staged"
}

replace_staged_file() {
	local source="$1"
	local target="$2"
	local staged

	register_staged_target "$target"
	staged="$(stage_file_for_write "$target")"
	mv "$source" "$staged"
}

copy_staged_file() {
	local source="$1"
	local target="$2"
	local staged

	register_staged_target "$target"
	staged="$(stage_file_for_write "$target")"
	cp -p "$source" "$staged"
}

commit_staged_files() {
	local target staged tmp

	for target in "${STAGED_TARGETS[@]}"; do
		staged="$(stage_target_path "$target")"
		[[ -f "$staged" ]] || die "Staged target disappeared: $staged"
		mkdir -p "$(dirname "$target")"
		tmp="$(mktemp "${target}.tmp.XXXXXX")"
		cp -p "$staged" "$tmp"
		mv -f "$tmp" "$target"
	done
}

validate_staged_files() {
	local target staged

	for target in "${STAGED_TARGETS[@]}"; do
		staged="$(stage_target_path "$target")"
		case "$target" in
		*.nix)
			nix-instantiate --parse "$staged" >/dev/null
			;;
		esac
	done

	if [[ -e "$(stage_target_path "$SECRETS_FILE")" || -d "$(stage_target_path "$MACHINE_SECRET_DIR")" ]]; then
		eval_staged_secrets >/dev/null
	fi
}

cleanup_run_dir() {
	local status=$?

	if [[ -n "$MUTATION_LOCK_DIR" && -d "$MUTATION_LOCK_DIR" ]]; then
		rm -rf "$MUTATION_LOCK_DIR"
	fi
	if [[ -n "$STORE_LOCK_DIR" && -d "$STORE_LOCK_DIR" ]]; then
		rm -rf "$STORE_LOCK_DIR"
	fi
	if [[ -n "$SECRET_RUN_DIR" ]]; then
		rm -rf "$SECRET_RUN_DIR"
	fi
	if [[ "$status" -ne 0 && -n "$RUN_DIR" && "$KEEP_TMP" != "1" ]]; then
		warn "Failure occurred with temporary files in ${RUN_DIR}; cleaning them up. Re-run with --keep-tmp to keep them."
	fi
	if [[ -n "$RUN_DIR" && "$KEEP_TMP" != "1" ]]; then
		rm -rf "$RUN_DIR"
	fi
	exit "$status"
}

lock_owner_pid() {
	local lock_dir="$1"
	local pid_file="${lock_dir}/pid"
	local pid

	[[ -f "$pid_file" ]] || return 1
	IFS= read -r pid <"$pid_file" || return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$pid"
}

lock_dir_old_enough_to_reap() {
	local lock_dir="$1"
	local mtime
	local now

	mtime="$(stat -c %Y "$lock_dir" 2>/dev/null)" || return 1
	now="$(date +%s)"
	((now - mtime >= 10))
}

acquire_mutation_lock() {
	local lock_dir="${REPO_ROOT}/tmp/host-manager.lock"
	local deadline=$((SECONDS + 60))
	local announced_wait="0"
	local owner

	mkdir -p "${REPO_ROOT}/tmp"
	while ! mkdir "$lock_dir" 2>/dev/null; do
		owner=""
		if owner="$(lock_owner_pid "$lock_dir")"; then
			if ! kill -0 "$owner" 2>/dev/null; then
				rm -rf "$lock_dir"
				continue
			fi
		elif lock_dir_old_enough_to_reap "$lock_dir"; then
			rm -rf "$lock_dir"
			continue
		fi
		if [[ "$announced_wait" != "1" ]]; then
			if [[ -n "$owner" ]]; then
				info "Waiting for host-manager mutation lock held by pid ${owner}: ${lock_dir}"
			else
				info "Waiting for host-manager mutation lock: ${lock_dir}"
			fi
			announced_wait="1"
		fi
		if ((SECONDS >= deadline)); then
			owner="$(lock_owner_pid "$lock_dir" || true)"
			if [[ -n "$owner" ]]; then
				die "Timed out waiting for host-manager mutation lock held by pid ${owner}: ${lock_dir}"
			fi
			die "Timed out waiting for host-manager mutation lock: ${lock_dir}"
		fi
		sleep 1
	done
	MUTATION_LOCK_DIR="$lock_dir"
	printf '%s\n' "$$" >"${lock_dir}/pid"
}

acquire_store_lock() {
	local lock_dir="${STORE_DIR%/}/.host-manager-build.lock"
	local deadline=$((SECONDS + 60))
	local announced_wait="0"
	local owner

	mkdir -p "$STORE_DIR"
	while ! mkdir "$lock_dir" 2>/dev/null; do
		owner=""
		if owner="$(lock_owner_pid "$lock_dir")"; then
			if ! kill -0 "$owner" 2>/dev/null; then
				rm -rf "$lock_dir"
				continue
			fi
		elif lock_dir_old_enough_to_reap "$lock_dir"; then
			rm -rf "$lock_dir"
			continue
		fi
		if [[ "$announced_wait" != "1" ]]; then
			if [[ -n "$owner" ]]; then
				info "Waiting for host-manager build-cache lock held by pid ${owner}: ${lock_dir}"
			else
				info "Waiting for host-manager build-cache lock: ${lock_dir}"
			fi
			announced_wait="1"
		fi
		if ((SECONDS >= deadline)); then
			owner="$(lock_owner_pid "$lock_dir" || true)"
			if [[ -n "$owner" ]]; then
				die "Timed out waiting for host-manager build-cache lock held by pid ${owner}: ${lock_dir}"
			fi
			die "Timed out waiting for host-manager build-cache lock: ${lock_dir}"
		fi
		sleep 1
	done
	STORE_LOCK_DIR="$lock_dir"
	printf '%s\n' "$$" >"${lock_dir}/pid"
}

root_cmd() {
	local cmd="$1"
	local cmd_path
	shift

	if [[ "${EUID}" -eq 0 ]]; then
		if [[ -n "$STORE_DIR" ]]; then
			env "NIX_CONFIG=$(store_nix_config "$STORE_DIR")" "$cmd" "$@"
			return
		fi
		"$cmd" "$@"
		return
	fi

	command -v sudo >/dev/null 2>&1 || die "Required command not found: sudo"
	cmd_path="$(command -v "$cmd")" || die "Required command not found: $cmd"
	if [[ -n "$STORE_DIR" ]]; then
		sudo env "NIX_CONFIG=$(store_nix_config "$STORE_DIR")" "$cmd_path" "$@"
		return
	fi
	sudo "$cmd_path" "$@"
}

nix_cmd() {
	if [[ -n "$STORE_DIR" ]]; then
		nix \
			--option substituters "$(store_url "$STORE_DIR")" \
			--option require-sigs false \
			"$@"
		return
	fi

	nix "$@"
}

nix_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
}

nix_attr_key() {
	local name="$1"

	if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_\'-]*$ ]]; then
		printf '%s' "$name"
	else
		printf '"%s"' "$(nix_escape "$name")"
	fi
}

regex_escape() {
	local value="$1"

	# shellcheck disable=SC2001,SC2016
	sed -e 's/[][\.^$*+?{}()|\\]/\\&/g' <<<"$value"
}

nix_attr_assignment_regex() {
	local name
	name="$(regex_escape "$1")"

	printf '^[[:space:]]*("%s"|%s)[[:space:]]*=' "$name" "$name"
}

load_nixbot_config_json() {
	local base_json override_json

	if [[ -n "$NIXBOT_CONFIG_JSON" ]]; then
		printf '%s\n' "$NIXBOT_CONFIG_JSON"
		return
	fi

	base_json="$(nix eval --json --file "$NIXBOT_FILE")"
	if [[ -f "$NIXBOT_OVERRIDE_FILE" ]]; then
		override_json="$(nix eval --json --file "$NIXBOT_OVERRIDE_FILE")"
		NIXBOT_CONFIG_JSON="$(jq -cs '.[0] * .[1]' <<<"${base_json}"$'\n'"${override_json}")"
	else
		NIXBOT_CONFIG_JSON="$base_json"
	fi
	printf '%s\n' "$NIXBOT_CONFIG_JSON"
}

load_nixbot_hosts_json() {
	local config_json

	if [[ -n "$NIXBOT_HOSTS_JSON" ]]; then
		printf '%s\n' "$NIXBOT_HOSTS_JSON"
		return
	fi

	config_json="$(load_nixbot_config_json)"
	NIXBOT_HOSTS_JSON="$(jq -c '.hosts // {}' <<<"$config_json")"
	printf '%s\n' "$NIXBOT_HOSTS_JSON"
}

load_nixbot_groups_json() {
	local hosts_json

	if [[ -n "$NIXBOT_GROUPS_JSON" ]]; then
		printf '%s\n' "$NIXBOT_GROUPS_JSON"
		return
	fi

	hosts_json="$(load_nixbot_hosts_json)"
	NIXBOT_GROUPS_JSON="$(jq -ce '
    def stable_unique:
      reduce .[] as $item ([]; if index($item) then . else . + [$item] end);
    if type == "object" then . else error("hosts must be an attrset") end
    | to_entries
    | reduce .[] as $host ({};
        (
          ($host.value.groups // [])
          | if type == "array" then .
            else error("host groups must be lists")
            end
          | map(
              if type == "string" and length > 0 then .
              else error("host groups must contain non-empty strings")
              end
            )
          | map(select(startswith("-") | not))
        ) as $groups
        | reduce $groups[] as $group (.;
            .[$group] = ((.[$group] // []) + [$host.key])
          )
      )
    | with_entries(.value |= stable_unique)
  ' <<<"$hosts_json")" || die "Nixbot host groups must be lists of non-empty strings."
	printf '%s\n' "$NIXBOT_GROUPS_JSON"
}

nixbot_inventory_hosts() {
	local hosts_json host_count

	hosts_json="$(load_nixbot_hosts_json)"
	host_count="$(jq -r 'keys | length' <<<"$hosts_json")"
	[[ "$host_count" -gt 0 ]] || die "No hosts found in ${NIXBOT_FILE}."
	jq -r 'keys[]' <<<"$hosts_json"
}

emit_normalized_hosts() {
	local raw="$1"

	printf '%s' "$raw" |
		tr ', ' '\n' |
		awk 'NF && !seen[$0]++'
}

host_token_is_glob() {
	local token="$1"

	case "$token" in
	*'*'* | *'?'* | *'['*) return 0 ;;
	*) return 1 ;;
	esac
}

resolve_maintenance_host_selectors() {
	local raw_selectors="$1" all_hosts_output groups_json="" token selector host matched exclusion=0
	local group_selector group group_matches
	local -a all_hosts=() group_names=() selected_hosts=() excluded_hosts=()
	declare -A group_host_set=() selected_host_set=() excluded_host_set=() inventory_host_set=()

	all_hosts_output="$(nixbot_inventory_hosts)" || return "$?"
	mapfile -t all_hosts <<<"$all_hosts_output"
	for host in "${all_hosts[@]}"; do
		inventory_host_set["$host"]=1
	done

	# Keep selector semantics aligned with nixbot's parse_host_selectors_json.
	while IFS= read -r token; do
		[[ -n "$token" ]] || continue
		exclusion=0
		selector="$token"
		if [[ "$token" == -* ]]; then
			exclusion=1
			selector="${token#-}"
			[[ -n "$selector" ]] || selector="$token"
		fi

		if [[ "$selector" == group:* ]]; then
			group_selector="${selector#group:}"
			[[ -n "$group_selector" ]] || die "Group selector cannot be empty."
			if [[ -z "$groups_json" ]]; then
				groups_json="$(load_nixbot_groups_json)" || return "$?"
				mapfile -t group_names < <(jq -r 'keys[]' <<<"$groups_json")
			fi

			matched=0
			group_host_set=()
			for group in "${group_names[@]}"; do
				group_matches=0
				if [[ "$group_selector" == "all" ]]; then
					group_matches=1
				elif host_token_is_glob "$group_selector"; then
					# shellcheck disable=SC2053
					if [[ "$group" == $group_selector ]]; then
						group_matches=1
					fi
				elif [[ "$group" == "$group_selector" ]]; then
					group_matches=1
				fi
				[[ "$group_matches" == "1" ]] || continue

				matched=1
				while IFS= read -r host; do
					[[ -n "$host" ]] || continue
					group_host_set["$host"]=1
				done < <(jq -r --arg group "$group" '.[$group][]' <<<"$groups_json")
			done

			if [[ "$matched" == "0" ]]; then
				[[ "$exclusion" == "1" ]] || die "Unknown group selector: ${group_selector}"
				continue
			fi

			for host in "${all_hosts[@]}"; do
				[[ -n "${group_host_set["$host"]+x}" ]] || continue
				if [[ "$exclusion" == "1" ]]; then
					if [[ -z "${excluded_host_set["$host"]+x}" ]]; then
						excluded_host_set["$host"]=1
						excluded_hosts+=("$host")
					fi
				elif [[ -z "${selected_host_set["$host"]+x}" ]]; then
					selected_host_set["$host"]=1
					selected_hosts+=("$host")
				fi
			done
			continue
		fi

		if [[ "$selector" == "all" ]]; then
			for host in "${all_hosts[@]}"; do
				if [[ "$exclusion" == "1" ]]; then
					if [[ -z "${excluded_host_set["$host"]+x}" ]]; then
						excluded_host_set["$host"]=1
						excluded_hosts+=("$host")
					fi
				elif [[ -z "${selected_host_set["$host"]+x}" ]]; then
					selected_host_set["$host"]=1
					selected_hosts+=("$host")
				fi
			done
			continue
		fi

		if host_token_is_glob "$selector"; then
			matched=0
			for host in "${all_hosts[@]}"; do
				# shellcheck disable=SC2053
				if [[ "$host" == $selector ]]; then
					matched=1
					if [[ "$exclusion" == "1" ]]; then
						if [[ -z "${excluded_host_set["$host"]+x}" ]]; then
							excluded_host_set["$host"]=1
							excluded_hosts+=("$host")
						fi
					elif [[ -z "${selected_host_set["$host"]+x}" ]]; then
						selected_host_set["$host"]=1
						selected_hosts+=("$host")
					fi
				fi
			done
			if [[ "$matched" == "0" && "$exclusion" == "0" ]]; then
				die "Unknown host selector: ${selector}"
			fi
			continue
		fi

		if [[ "$exclusion" == "1" ]]; then
			if [[ -z "${excluded_host_set["$selector"]+x}" ]]; then
				excluded_host_set["$selector"]=1
				excluded_hosts+=("$selector")
			fi
		elif [[ -z "${inventory_host_set["$selector"]+x}" ]]; then
			die "Unknown host selector: ${selector}"
		elif [[ -z "${selected_host_set["$selector"]+x}" ]]; then
			selected_host_set["$selector"]=1
			selected_hosts+=("$selector")
		fi
	done < <(emit_normalized_hosts "$raw_selectors")

	if [[ "${#selected_hosts[@]}" == "0" && "${#excluded_hosts[@]}" -gt 0 ]]; then
		selected_hosts=("${all_hosts[@]}")
	fi

	matched=0
	for host in "${selected_hosts[@]}"; do
		[[ -z "${excluded_host_set["$host"]+x}" ]] || continue
		printf '%s\n' "$host"
		matched=1
	done
	[[ "$matched" == "1" ]] || die "No hosts selected."
}

nixbot_host_json() {
	local host="$1" hosts_json

	hosts_json="$(load_nixbot_hosts_json)"
	jq -cer --arg host "$host" '.[$host] // empty' <<<"$hosts_json"
}

nixbot_host_registered() {
	local host="$1"

	nixbot_host_json "$host" >/dev/null 2>&1
}

prepare_ssh_context() {
	local host="$1" mode="${2:-remote}" host_json target proxy_jump proxy_command user key_path

	host_json="$(nixbot_host_json "$host")" || die "Host is not in ${NIXBOT_FILE}: ${host}"
	target="$(jq -r --arg host "$host" '.target // $host' <<<"$host_json")"
	proxy_jump="$(jq -r '.proxyJump // empty' <<<"$host_json")"
	proxy_command="$(jq -r '.proxyCommand // empty' <<<"$host_json")"
	{
		read -r user
		read -r key_path
	} < <(nixbot_operator_context "$host")

	REMOTE_SSH_ARGS=()
	if [[ "$mode" == "remote" ]]; then
		REMOTE_SSH_ARGS+=(
			-o BatchMode=yes
			-o ConnectTimeout=15
			-o ConnectionAttempts=1
		)
	fi
	if [[ -n "$proxy_command" ]]; then
		REMOTE_SSH_ARGS+=(-o "ProxyCommand=${proxy_command}")
	elif [[ -n "$proxy_jump" ]]; then
		if nixbot_host_registered "$proxy_jump"; then
			ensure_remote_ssh_config
		else
			REMOTE_SSH_ARGS+=(-J "$proxy_jump")
		fi
	fi
	if [[ -n "$key_path" ]]; then
		REMOTE_SSH_ARGS+=(-i "$(resolve_operator_key_path "$key_path")" -o IdentitiesOnly=yes)
	fi

	if [[ -n "$REMOTE_SSH_CONFIG" ]]; then
		REMOTE_SSH_ARGS+=(-F "$REMOTE_SSH_CONFIG")
		REMOTE_SSH_TARGET="$(ssh_inventory_alias "$host")"
		return
	fi
	if [[ "$target" == *@* || -z "$user" ]]; then
		REMOTE_SSH_TARGET="$target"
	else
		REMOTE_SSH_TARGET="${user}@${target}"
	fi
}

ssh_inventory_alias() {
	printf 'host-manager-%s\n' "$1"
}

ensure_remote_ssh_config() {
	local config_json host

	if [[ -n "$REMOTE_SSH_CONFIG" ]]; then
		return
	fi
	[[ -n "$RUN_DIR" ]] || die "Internal error: RUN_DIR is required before preparing inventory SSH config."

	REMOTE_SSH_CONFIG="${RUN_DIR}/ssh_config"
	config_json="$(load_nixbot_config_json)"
	: >"$REMOTE_SSH_CONFIG"
	chmod 600 "$REMOTE_SSH_CONFIG"
	while IFS= read -r host; do
		[[ -n "$host" ]] || continue
		append_ssh_config_host "$config_json" "$host" >>"$REMOTE_SSH_CONFIG"
	done < <(jq -r '.hosts // {} | keys[]' <<<"$config_json")
}

append_ssh_config_host() {
	local config_json="$1" host="$2"
	local host_json target proxy_jump proxy_command user key_path

	host_json="$(jq -cer --arg host "$host" '.hosts[$host]' <<<"$config_json")"
	target="$(jq -r --arg host "$host" '.target // $host' <<<"$host_json")"
	proxy_jump="$(jq -r '.proxyJump // empty' <<<"$host_json")"
	proxy_command="$(jq -r '.proxyCommand // empty' <<<"$host_json")"
	{
		read -r user
		read -r key_path
	} < <(nixbot_operator_context_from_config "$config_json" "$host")

	printf 'Host %s\n' "$(ssh_inventory_alias "$host")"
	if ssh_known_host_exists "$host"; then
		printf '  HostKeyAlias %s\n' "$host"
	fi
	if [[ "$target" == *@* ]]; then
		printf '  User %s\n' "${target%@*}"
		printf '  HostName %s\n' "${target#*@}"
	else
		printf '  HostName %s\n' "$target"
		if [[ -n "$user" ]]; then
			printf '  User %s\n' "$user"
		fi
	fi
	if [[ -n "$key_path" ]]; then
		printf '  IdentityFile %s\n' "$(resolve_operator_key_path "$key_path")"
		printf '  IdentitiesOnly yes\n'
	fi
	if [[ -n "$proxy_command" ]]; then
		printf '  ProxyCommand %s\n' "$proxy_command"
	elif [[ -n "$proxy_jump" ]]; then
		if jq -e --arg host "$proxy_jump" '.hosts // {} | has($host)' <<<"$config_json" >/dev/null; then
			printf '  ProxyJump %s\n' "$(ssh_inventory_alias "$proxy_jump")"
		else
			printf '  ProxyJump %s\n' "$proxy_jump"
		fi
	fi
	printf '\n'
}

nixbot_operator_context() {
	local host="$1" config_json

	config_json="$(load_nixbot_config_json)"
	nixbot_operator_context_from_config "$config_json" "$host"
}

nixbot_operator_context_from_config() {
	local config_json="$1" host="$2"

	jq -r \
		--arg host "$host" \
		--arg fallbackUser "$OP_USER" \
		--arg explicitUser "$OP_USER_EXPLICIT" '
    def pick($values):
      $values
      | map((. // "") | tostring)
      | map(select(. != ""))
      | .[0] // "";
    (.hosts[$host] // {}) as $hostCfg
    | (.config.hostDefaults // {}) as $defaults
    | (pick([$hostCfg.operatorUser, $defaults.operatorUser])) as $inventoryUser
    | (pick([$hostCfg.operatorKey, $defaults.operatorKey])) as $inventoryKey
    | if $explicitUser == "1" then
        [$fallbackUser, (if $fallbackUser == $inventoryUser then $inventoryKey else "" end)]
      else
        [pick([$inventoryUser, $fallbackUser]), $inventoryKey]
      end
    | .[]
	' <<<"$config_json"
}

resolve_operator_key_path() {
	local key_path="$1"

	if [[ -z "$key_path" || "$key_path" = /* ]]; then
		printf '%s\n' "$key_path"
	else
		printf '%s/%s\n' "$REPO_ROOT" "$key_path"
	fi
}

ssh_known_host_exists() {
	ssh-keygen -F "$1" >/dev/null 2>&1
}

run_remote_root_script() {
	local host="$1" script="$2"
	local remote_command
	shift 2

	prepare_ssh_context "$host" remote
	remote_command="$(shell_quote_argv sudo -n env "$@" bash -s)"
	ssh "${REMOTE_SSH_ARGS[@]}" "$REMOTE_SSH_TARGET" "$remote_command" <<<"$script"
}

shell_quote_argv() {
	local arg
	printf '%q' "$1"
	shift
	for arg in "$@"; do
		printf ' %q' "$arg"
	done
}

resolve_service_hosts_from_stack() {
	local service="$1" stack="$2"
	local policy_path_escaped stack_attr service_escaped stack_escaped

	policy_path_escaped="$(nix_escape "$HOST_MANAGER_POLICY_FILE")"
	stack_attr="$(nix_attr_key "$stack")"
	stack_escaped="$(nix_escape "$stack")"
	service_escaped="$(nix_escape "$service")"

	nix eval --json --file "${REPO_ROOT}/lib/stacks/default.nix" --apply "
stacks: let
  policy = import (builtins.toPath "${policy_path_escaped}");
  stack = stacks.${stack_attr} or (throw \"unknown stack: ${stack_escaped}\");
  registry = stack.serviceRegistry;
  service = registry.serviceFor \"${service_escaped}\";
  endpointGroups =
    if service ? placement
    then [service.placement]
    else builtins.attrNames registry.endpointGroups;
  hosts = map (
    group:
      policy.serviceDeploymentHost {
        stackName = stack.stackName;
        endpoint = registry.endpointForGroup service.role group;
      }
  ) endpointGroups;
  uniqueHosts = builtins.attrNames (builtins.listToAttrs (map (host: {
    name = host;
    value = true;
  }) hosts));
in
  uniqueHosts
" | jq -r '.[]'
}

resolve_service_runtime_from_stack() {
	local stack="$1" stack_attr stack_escaped

	stack_attr="$(nix_attr_key "$stack")"
	stack_escaped="$(nix_escape "$stack")"

	nix eval --json --file "${REPO_ROOT}/lib/stacks/default.nix" --apply "
stacks: let
  stack = stacks.${stack_attr} or (throw \"unknown stack: ${stack_escaped}\");
in {
  prefix = \"\${stack.srv.defaultUser}-\";
  user = stack.srv.defaultUser;
}
" | jq -r '.prefix, .user'
}

service_name_is_unit() {
	local service="$1"

	[[ "$service" == *.service || "$service" == *.target ]]
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

# These probes intentionally match the repo's alejandra-formatted Nix shape.
host_registered() {
	local source_file
	local host_pattern

	source_file="$(target_read_path "$HOSTS_DEFAULT_FILE")"
	host_pattern="$(nix_attr_assignment_regex "$HOST")"
	grep -Eq "${host_pattern}[[:space:]]*mk[A-Za-z0-9_'-]*[^{;]*\\{" "$source_file"
}

has_nixbot_entry() {
	grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*\\{" "$(target_read_path "$NIXBOT_FILE")"
}

has_machine_secret_registration() {
	local source_file

	source_file="$(target_read_path "$SECRETS_FILE")"
	grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*\\{\\};" "$source_file" ||
		grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*./globals/machine/$(regex_escape "$HOST")\\.key\\.pub;" "$source_file" ||
		grep -Fq "\"data/secrets/globals/machine/${HOST}.key.age\"" "$source_file"
}

has_machine_key_files() {
	[[ -e "${MACHINE_SECRET_DIR}/${HOST}.key" ||
		-e "${MACHINE_SECRET_DIR}/${HOST}.key.pub" ||
		-e "${MACHINE_SECRET_DIR}/${HOST}.key.age" ||
		-e "$(stage_target_path "${MACHINE_SECRET_DIR}/${HOST}.key.pub")" ||
		-e "$(stage_target_path "${MACHINE_SECRET_DIR}/${HOST}.key.age")" ]]
}

ensure_host_absent_or_confirm() {
	if host_registered || [[ -e "$HOST_DIR" ]]; then
		info "Host already exists: ${HOST}"
		return
	fi

	if [[ "$YES_CREATE_HOST" != "1" ]]; then
		confirm_or_die "Host ${HOST} does not exist. Create it?" "--yes-create-host or --force" 1
	fi
}

write_physical_host_default() {
	local stack_expr="null" target_file

	register_staged_target "${HOST_DIR}/default.nix"
	target_file="$(stage_file_for_write "${HOST_DIR}/default.nix")"
	if [[ -n "$HOST_STACK" ]]; then
		stack_expr="\"$(nix_escape "$HOST_STACK")\""
	fi
	cat >"$target_file" <<EOF
{...}: let
  policy = import ../../pkgs/tools/host-manager/policy.nix;
in {
  imports =
    policy.generatedHostModules {
      stackName = ${stack_expr};
      system = "vm";
    }
    ++ [./sys.nix];
}
EOF
	alejandra -q "$target_file"
}

write_lxc_host_default() {
	local default_file packages_file stack_expr="null" users_file

	register_staged_target "${HOST_DIR}/default.nix"
	register_staged_target "${HOST_DIR}/packages.nix"
	register_staged_target "${HOST_DIR}/users.nix"
	default_file="$(stage_file_for_write "${HOST_DIR}/default.nix")"
	packages_file="$(stage_file_for_write "${HOST_DIR}/packages.nix")"
	users_file="$(stage_file_for_write "${HOST_DIR}/users.nix")"
	if [[ -n "$HOST_STACK" ]]; then
		stack_expr="\"$(nix_escape "$HOST_STACK")\""
	fi
	cat >"$default_file" <<EOF
{...}: let
  policy = import ../../pkgs/tools/host-manager/policy.nix;
in {
  imports =
    policy.generatedHostModules {
      stackName = ${stack_expr};
      system = "incusLxc";
    }
    ++ [
      ./packages.nix
      ./users.nix
    ];
}
EOF
	printf '{...}: {}\n' >"$packages_file"
	printf '{...}: {}\n' >"$users_file"
	alejandra -q "$default_file" "$packages_file" "$users_file"
}

register_host() {
	local entry_file="${RUN_DIR}/host-entry.nix"
	local next_hosts="${RUN_DIR}/hosts-default.nix"
	local host_attr
	local machine_profile
	local source_file

	host_registered && return
	host_attr="$(nix_attr_key "$HOST")"
	if [[ "$HOST_SYSTEM" == "incus" ]]; then
		machine_profile="machineProfiles.incusLxc"
	else
		machine_profile="machineProfiles.vm"
	fi

	cat >"$entry_file" <<EOF
  ${host_attr} = mkNixosSystem {
    hostName = "$(nix_escape "$HOST")";
    machineProfile = ${machine_profile};
EOF
	if [[ -n "$HOST_STACK" ]]; then
		cat >>"$entry_file" <<EOF
    stack = stacks.$(nix_attr_key "$HOST_STACK");
EOF
	fi
	cat >>"$entry_file" <<EOF
    modules = [./${HOST}];
  };

EOF

	source_file="$(target_read_path "$HOSTS_DEFAULT_FILE")"
	insert_before_final_brace "$entry_file" "$source_file" "$next_hosts"
	alejandra -q "$next_hosts"
	replace_staged_file "$next_hosts" "$HOSTS_DEFAULT_FILE"
}

insert_before_final_brace() {
	local entry_file="$1"
	local target_file="$2"
	local output_file="$3"

	# Text insertion relies on the repo's formatted top-level closing brace.
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

eval_staged_secrets() {
	local eval_root="${RUN_DIR}/secrets-eval"
	local eval_secrets_dir="${eval_root}/data/secrets"
	local eval_machine_dir="${eval_secrets_dir}/globals/machine"
	local pub_file staged_pub_file staged_machine_dir secrets_source stack_dir globals_family

	rm -rf "$eval_root"
	mkdir -p "$eval_machine_dir"
	ln -s "$REPO_ROOT/lib" "${eval_root}/lib"
	ln -s "$REPO_ROOT/hosts" "${eval_root}/hosts"
	ln -s "$REPO_ROOT/users" "${eval_root}/users"
	for stack_dir in "$REPO_ROOT"/data/secrets/*; do
		[[ -d "$stack_dir" ]] || continue
		case "$(basename "$stack_dir")" in
		globals) ;;
		*) ln -s "$stack_dir" "${eval_secrets_dir}/$(basename "$stack_dir")" ;;
		esac
	done
	mkdir -p "${eval_secrets_dir}/globals"
	for globals_family in "$REPO_ROOT"/data/secrets/globals/*; do
		[[ -d "$globals_family" ]] || continue
		case "$(basename "$globals_family")" in
		machine) ;;
		*) ln -s "$globals_family" "${eval_secrets_dir}/globals/$(basename "$globals_family")" ;;
		esac
	done
	for pub_file in "$MACHINE_SECRET_DIR"/*.key.pub; do
		[[ -e "$pub_file" ]] || continue
		ln -s "$pub_file" "${eval_machine_dir}/$(basename "$pub_file")"
	done
	staged_machine_dir="$(stage_target_path "$MACHINE_SECRET_DIR")"
	if [[ -d "$staged_machine_dir" ]]; then
		for staged_pub_file in "$staged_machine_dir"/*.key.pub; do
			[[ -e "$staged_pub_file" ]] || continue
			ln -sf "$staged_pub_file" "${eval_machine_dir}/$(basename "$staged_pub_file")"
		done
	fi
	secrets_source="$(target_read_path "$SECRETS_FILE")"
	cp "$secrets_source" "${eval_secrets_dir}/default.nix"
	nix eval --json --file "${eval_secrets_dir}/default.nix"
}

ensure_machine_age_identity() {
	local tmp_key_file="${SECRET_RUN_DIR}/${HOST}.key"
	local pub_file="${MACHINE_SECRET_DIR}/${HOST}.key.pub"
	local age_file="${MACHINE_SECRET_DIR}/${HOST}.key.age"
	local staged_pub_file staged_age_file target_pub_file target_age_file
	local public_line
	local recipients_json
	local -a recipients=()
	local -a age_args=()
	local recipient

	register_machine_secret

	staged_pub_file="$(stage_target_path "$pub_file")"
	staged_age_file="$(stage_target_path "$age_file")"

	if [[ -f "$pub_file" && -f "$age_file" ]] || [[ -f "$staged_pub_file" && -f "$staged_age_file" ]]; then
		info "Machine age identity already exists: data/secrets/globals/machine/${HOST}.key.age"
		return
	fi

	if [[ -e "${MACHINE_SECRET_DIR}/${HOST}.key" || -e "$pub_file" || -e "$age_file" || -e "$staged_pub_file" || -e "$staged_age_file" ]]; then
		die "Partial machine identity exists for ${HOST}; inspect data/secrets/globals/machine/${HOST}.key* before continuing."
	fi

	public_line="$(age-keygen -o "$tmp_key_file" 2>&1 | awk -F': ' '/^Public key:/ {print $2}')"
	[[ -n "$public_line" ]] || die "age-keygen did not print a public key."
	register_staged_target "$pub_file"
	target_pub_file="$(stage_file_for_write "$pub_file")"
	printf '%s\n' "$public_line" >"$target_pub_file"

	recipients_json="$(eval_staged_secrets)"
	mapfile -t recipients < <(jq -r --arg path "data/secrets/globals/machine/${HOST}.key.age" '.[$path].publicKeys[]? // empty' <<<"$recipients_json")
	[[ "${#recipients[@]}" -gt 0 ]] || die "No recipients configured for data/secrets/globals/machine/${HOST}.key.age"

	for recipient in "${recipients[@]}"; do
		age_args+=(-r "$recipient")
	done

	register_staged_target "$age_file"
	target_age_file="$(stage_file_for_write "$age_file")"
	age "${age_args[@]}" -o "$target_age_file" "$tmp_key_file"
	rm -f -- "$tmp_key_file"
	info "Created machine age identity: data/secrets/globals/machine/${HOST}.key.age"
}

register_machine_secret() {
	local source_file
	local machine_identity_file="${RUN_DIR}/secrets-default-machine-identity.nix"
	local host_attr

	host_attr="$(nix_attr_key "$HOST")"
	source_file="$(target_read_path "$SECRETS_FILE")"
	if ! grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*\\{\\};" "$source_file"; then
		awk -v host="$HOST" -v host_attr="$host_attr" '
			{
				if ($0 ~ /^    machines = \{/) {
					in_machines = 1
				}
				if (in_machines && $0 ~ /^    \};/) {
					printf "      %s = {};\n", host_attr
					inserted = 1
					in_machines = 0
				}
				print
			}

			END {
				if (!inserted) {
					exit 1
				}
			}
		' "$source_file" >"$machine_identity_file" || die "Could not register machine identity in ${SECRETS_FILE}."
		alejandra -q "$machine_identity_file"
		copy_staged_file "$machine_identity_file" "$SECRETS_FILE"
	fi
}

ensure_nixbot_entry() {
	local target="$NIXBOT_TARGET"
	local proxy_jump="$PROXY_JUMP"
	local entry_file="${RUN_DIR}/nixbot-entry.nix"
	local next_file="${RUN_DIR}/nixbot.nix"
	local host_attr
	local source_file

	has_nixbot_entry && return
	host_attr="$(nix_attr_key "$HOST")"

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
    ${host_attr} = {
      target = "$(nix_escape "$target")";
      ageIdentityKey = secretPaths.machine "$(nix_escape "$HOST")";
EOF
	if [[ -n "$proxy_jump" ]]; then
		cat >>"$entry_file" <<EOF
      proxyJump = "$(nix_escape "$proxy_jump")";
EOF
	fi
	if [[ -n "$INCUS_HOST" ]]; then
		cat >>"$entry_file" <<EOF
      parent = "$(nix_escape "$INCUS_HOST")";
EOF
	fi
	cat >>"$entry_file" <<'EOF'
    };
EOF

	source_file="$(target_read_path "$NIXBOT_FILE")"
	insert_into_attrset "$entry_file" "$source_file" "$next_file" '^  hosts = [{]$' '^  [}];$'
	alejandra -q "$next_file"
	replace_staged_file "$next_file" "$NIXBOT_FILE"
}

insert_into_attrset() {
	local entry_file="$1"
	local target_file="$2"
	local output_file="$3"
	local start_pattern="$4"
	local end_pattern="$5"

	# Text insertion is scoped to the first matching formatted attrset anchor.
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
    boot = diskoLib.mkEfiBoot {
      size = "$(nix_escape "$ESP_SIZE")";
      partUuid = "$(nix_escape "$BOOT_PART_UUID")";
    };
EOF
	else
		cat <<EOF
    boot = diskoLib.mkBiosBoot {
      biosBoot = {
        partUuid = "$(nix_escape "$BIOS_PART_UUID")";
      };
      boot = diskoLib.mkExt4Boot {
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

	disko_import="../../lib/disko"

	{
		cat <<EOF
# Hardware and install-storage config. Generated by host-manager.
{
  config,
  lib,
  modulesPath,
  ...
}: let
  diskoLib = import ../../lib/disko/lib.nix {lib = lib;};
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ${disko_import}
  ];

  disko.devices.disk.main = diskoLib.mkMain {
    diskDevice = "$(nix_escape "$DISK_DEVICE")";
EOF
		print_boot_config
		cat <<EOF
    root = diskoLib.mkLuksBtrfs {
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
	local source_file

	source_file="$(target_read_path "$target_file")"
	if [[ -e "$source_file" && ! -s "$GENERATED_SYS_FILE" ]]; then
		return
	fi

	if [[ -e "$source_file" ]]; then
		if cmp -s "$GENERATED_SYS_FILE" "$source_file"; then
			info "Generated sys.nix matches existing file: $target_file"
			return
		fi
		confirm_or_die "Generated sys.nix differs from existing ${target_file}. Overwrite it?" "--force" 1
	fi

	alejandra -q "$GENERATED_SYS_FILE"
	copy_staged_file "$GENERATED_SYS_FILE" "$target_file"
	info "Generated sys.nix: $target_file"
}

ensure_incus_instance() {
	local parent_file="${REPO_ROOT}/hosts/${INCUS_HOST}/incus.nix"
	local entry_file="${RUN_DIR}/incus-entry.nix"
	local next_file="${RUN_DIR}/incus.nix"
	local host_attr
	local incus_project="${INCUS_PROJECT:-default}"
	local source_file

	host_attr="$(nix_attr_key "$HOST")"
	source_file="$(target_read_path "$parent_file")"
	if grep -Eq "$(nix_attr_assignment_regex "$HOST")" "$source_file"; then
		info "Incus instance already exists on ${INCUS_HOST}: ${HOST}"
		return
	fi

	cat >"$entry_file" <<EOF
      ${host_attr} = {
        ipv4Address = "${INCUS_IPV4}";
        config = {
          "security.privileged" = "false";
        };
        devices = {
          state = {
            source = "$(nix_escape "$HOST")";
            path = "/var/lib";
            removalPolicy = "delete";
          };
        };
      };
EOF

	insert_into_attrset "$entry_file" "$source_file" "$next_file" "^[[:space:]]*$(regex_escape "$incus_project")[.]instances = [{]$" '^      [}];$'
	alejandra -q "$next_file"
	replace_staged_file "$next_file" "$parent_file"
	info "Added Incus instance ${incus_project}/${HOST} to hosts/${INCUS_HOST}/incus.nix"
}

run_build() {
	local cache_url
	local system_ref
	local system_path
	local system_path_marker
	local tmp_marker
	local -a runtime_installables=()
	local -a runtime_paths=()

	acquire_store_lock
	cache_url="$(store_url "$STORE_DIR")"
	system_ref="${REPO_ROOT}#nixosConfigurations.${HOST}.config.system.build.toplevel"
	system_path_marker="${STORE_DIR}/host-${HOST}.system-path"
	tmp_marker="${system_path_marker}.tmp.$$"

	info "Archiving flake inputs to ${cache_url}"
	nix flake archive --to "$cache_url" "$REPO_ROOT"

	info "Building system closure for .#${HOST}"
	system_path="$(nix build --no-link --print-out-paths "$system_ref")"

	info "Building host-manager runtime dependency closures"
	mapfile -t runtime_installables < <(runtime_packages)
	mapfile -t runtime_paths < <(nix build --inputs-from "$REPO_ROOT" --no-link --print-out-paths "${runtime_installables[@]}")

	info "Copying system and runtime closures to ${cache_url}"
	nix copy --to "$cache_url" "$system_path" "${runtime_paths[@]}"

	printf '%s\n' "$system_path" >"$tmp_marker"
	mv -f "$tmp_marker" "$system_path_marker"
	info "Cached ${HOST} system closure in ${STORE_DIR}"
	info "Recorded system path: ${system_path_marker}"
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
	else
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
	fi

	validate_staged_files
	commit_staged_files
}

host_uses_efi_boot() {
	grep -Eq 'mkEfiBoot' "${HOST_DIR}/sys.nix"
}

run_install() {
	info "Checking disko target for .#${HOST}"
	if ! nix_cmd eval "${REPO_ROOT}#nixosConfigurations.${HOST}.config.disko.devices.disk.main.device" >/dev/null 2>"${RUN_DIR}/disko-eval.err"; then
		if ! grep -Eq '^[[:space:]]*disko\.devices\.disk\.main[[:space:]]*=' "${HOST_DIR}/sys.nix"; then
			die "Host ${HOST} has no disko config. Regenerate it with --disk or --system=live before live-install."
		fi
		cat "${RUN_DIR}/disko-eval.err" >&2
		die "Could not evaluate disko target for ${HOST}."
	fi

	if [[ "$DRY_RUN" == "1" ]]; then
		info "Dry run; would run:"
		print_install_commands >&2
		return
	fi

	if host_uses_efi_boot; then
		[[ -d /sys/firmware/efi/efivars ]] || die "Host ${HOST} uses EFI boot, but this live environment is not booted with EFI variables."
	fi

	# --wipe-disks allows entry; the two prompts still guard each destructive phase.
	confirm_or_die "Run disko for ${HOST}? This will destroy, format, and mount the disks declared by the host disko config." "--yes"
	info "Running disko for .#${HOST}; only disks declared by that host disko config are formatted."
	root_cmd disko --mode destroy,format,mount --flake "${REPO_ROOT}#${HOST}" --root-mountpoint "$ROOT_MOUNT" --yes-wipe-all-disks

	confirm_or_die "Run nixos-install for ${HOST} into ${ROOT_MOUNT}?" "--yes"
	info "Running nixos-install for .#${HOST}"
	if [[ -n "$STORE_DIR" ]]; then
		root_cmd nixos-install \
			--option substituters "$(store_url "$STORE_DIR")" \
			--option require-sigs false \
			--flake "${REPO_ROOT}#${HOST}" \
			--root "$ROOT_MOUNT" \
			--no-root-passwd
		return
	fi

	root_cmd nixos-install --flake "${REPO_ROOT}#${HOST}" --root "$ROOT_MOUNT" --no-root-passwd
}

run_ssh() {
	prepare_ssh_context "$HOST" interactive
	exec ssh "${REMOTE_SSH_ARGS[@]}" "$REMOTE_SSH_TARGET" "${SSH_EXTRA_ARGS[@]}"
}

maintenance_target_hosts() {
	if [[ "$HOSTS_FROM_FLAG" == "1" ]]; then
		resolve_maintenance_host_selectors "$HOSTS_RAW"
	elif [[ "$HOST" == "all" ]]; then
		resolve_maintenance_host_selectors all
	else
		printf '%s\n' "$HOST"
	fi
}

maintenance_target_label() {
	if [[ "$HOSTS_FROM_FLAG" == "1" ]]; then
		printf 'selected nixbot inventory hosts (%s)\n' "$HOSTS_RAW"
	elif [[ "$HOST" == "all" ]]; then
		printf 'all nixbot inventory hosts\n'
	else
		printf '%s\n' "$HOST"
	fi
}

prefix_host_stream() {
	local host="$1"

	awk -v prefix="| ${host} | " '{ print prefix $0; fflush() }'
}

drain_host_jobs() {
	local rc=0 pid

	for pid in "$@"; do
		wait "$pid" || rc=1
	done
	return "$rc"
}

run_for_target_hosts() {
	local label="$1" runner="$2" host hosts_output active_jobs=0 rc=0
	local -a hosts=() pids=()

	hosts_output="$(maintenance_target_hosts)" || return "$?"
	mapfile -t hosts <<<"$hosts_output"
	if [[ "${#hosts[@]}" == "1" ]]; then
		"$runner" "${hosts[0]}"
		return
	fi

	for host in "${hosts[@]}"; do
		(
			info "==> ${label}"
			"$runner" "$host"
		) 2>&1 | prefix_host_stream "$host" &
		pids+=("$!")
		active_jobs=$((active_jobs + 1))
		if [[ "$active_jobs" -ge "$HOST_JOBS" ]]; then
			drain_host_jobs "${pids[@]}" || rc=1
			pids=()
			active_jobs=0
		fi
	done

	if [[ "$active_jobs" -gt 0 ]]; then
		drain_host_jobs "${pids[@]}" || rc=1
	fi
	return "$rc"
}

run_gc_host() {
	local host="$1" script gc_mode

	if [[ "$GC_ALL" == "1" ]]; then
		gc_mode="all"
	else
		gc_mode="older"
	fi

	script="$(
		cat <<'REMOTE_GC'
set -Eeuo pipefail
echo "Host: $(hostname)"
echo "Current system: $(readlink /run/current-system 2>/dev/null || true)"
if [[ "${HM_DRY_RUN}" == "1" ]]; then
	if [[ "${HM_GC_MODE}" == "all" ]]; then
		echo "DRY: nix-collect-garbage -d"
	else
		echo "DRY: nix-collect-garbage --delete-older-than ${HM_DELETE_OLDER_THAN}"
	fi
	nix store info 2>/dev/null || true
	exit 0
fi
if [[ "${HM_GC_MODE}" == "all" ]]; then
	nix-collect-garbage -d
else
	nix-collect-garbage --delete-older-than "${HM_DELETE_OLDER_THAN}"
fi
REMOTE_GC
	)"
	run_remote_root_script "$host" "$script" \
		HM_DRY_RUN="$DRY_RUN" \
		HM_GC_MODE="$gc_mode" \
		HM_DELETE_OLDER_THAN="$DELETE_OLDER_THAN"
}

run_gc() {
	local target_label

	target_label="$(maintenance_target_label)"

	if [[ "$DRY_RUN" != "1" ]]; then
		confirm_or_die "Run Nix garbage collection on ${target_label}?" "--yes"
	fi

	run_for_target_hosts gc run_gc_host
}

run_reboot_host() {
	local host="$1" script

	script="$(
		cat <<'REMOTE_REBOOT'
set -Eeuo pipefail
echo "Host: $(hostname)"
echo "Current system: $(readlink /run/current-system 2>/dev/null || true)"
if [[ "${HM_DRY_RUN}" == "1" ]]; then
	echo "DRY: systemctl reboot"
	exit 0
fi
systemctl reboot
REMOTE_REBOOT
	)"
	run_remote_root_script "$host" "$script" HM_DRY_RUN="$DRY_RUN"
}

run_reboot() {
	local target_label

	target_label="$(maintenance_target_label)"

	if [[ "$DRY_RUN" != "1" ]]; then
		confirm_or_die "Reboot ${target_label} by running systemctl reboot on the target host(s)?" "--yes"
	fi

	run_for_target_hosts reboot run_reboot_host
}

remote_lock_cleanup_script() {
	cat <<'REMOTE_CLEAN'
set -Eeuo pipefail

dry="${HM_DRY_RUN:-1}"
force_held="${HM_FORCE_HELD:-0}"
kind="${HM_CLEAN_KIND:-all}"

lock_holder_line() {
	local fd_path="$1" link_target="$2"
	local pid fd user comm cgroup

	pid="${fd_path#/proc/}"
	pid="${pid%%/*}"
	fd="${fd_path##*/}"
	user="$(stat -c %U "/proc/$pid" 2>/dev/null || printf '?')"
	comm="$(cat "/proc/$pid/comm" 2>/dev/null || printf '?')"
	cgroup="$(sed -n 's|^[^:]*:[^:]*:||p' "/proc/$pid/cgroup" 2>/dev/null | tail -n 1)"
	printf '  pid=%s fd=%s user=%s comm=%s cgroup=%s target=%s\n' \
		"$pid" "$fd" "$user" "$comm" "${cgroup:-?}" "$link_target"
}

lock_holder_lines_for_path() {
	local path="$1" fd_path link_target

	for fd_path in /proc/[0-9]*/fd/*; do
		[[ -e "$fd_path" ]] || continue
		link_target="$(readlink "$fd_path" 2>/dev/null || true)"
		case "$link_target" in
		"$path" | "$path (deleted)")
			lock_holder_line "$fd_path" "$link_target"
			;;
		esac
	done
}

clear_lock_path() {
	local path="$1" holders

	holders="$(lock_holder_lines_for_path "$path")"
	if [[ -n "$holders" ]]; then
		if [[ "$force_held" == "1" ]]; then
			printf 'force-remove held %s\n' "$path" >&2
		else
			printf 'held %s\n' "$path" >&2
		fi
		printf '%s\n' "$holders" >&2
		[[ "$force_held" == "1" ]] || return 1
	fi

	if [[ ! -e "$path" && ! -L "$path" ]]; then
		printf 'absent %s\n' "$path"
		return 0
	fi
	if [[ "$dry" == "1" ]]; then
		printf 'DRY remove %s\n' "$path"
	else
		printf 'remove %s\n' "$path"
		rm -rf -- "$path"
	fi
}

emit_nixbot_locks() {
	local root

	for root in /dev/shm/nixbot "${TMPDIR:-/tmp}/nixbot"; do
		[[ -d "$root" ]] || continue
		find "$root" -xdev -depth -path '*/state-locks/*.lock' -type d -print 2>/dev/null
		find "$root" -xdev -depth -name 'ssh-tty.lock' -type d -print 2>/dev/null
	done

	if [[ -d /var/lib/nixbot ]]; then
		find /var/lib/nixbot -xdev -depth \
			\( -name 'nixbot-worktree.lock' -o -name '.nixbot-worktree.lock' \) \
			-type d -print 2>/dev/null
	fi
}

emit_declared_podman_locks() {
	local registry="/run/current-system/share/podman-compose/control-registry.json"
	local metadata_file working_dir

	[[ -f "$registry" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	while IFS= read -r metadata_file; do
		[[ -n "$metadata_file" && -f "$metadata_file" ]] || continue
		working_dir="$(jq -r '.workingDir // empty' "$metadata_file" 2>/dev/null || true)"
		[[ -n "$working_dir" ]] || continue
		printf '%s/.podman-compose/lifecycle.lock\n' "$working_dir"
	done < <(jq -r 'to_entries[]?.value.metadataFile // empty' "$registry" 2>/dev/null || true)
}

emit_podman_locks() {
	{
		[[ -d /run/user ]] && find /run/user -xdev -path '*/podman-compose/rootless-lifecycle-v1.lock' -type f -print 2>/dev/null || true
		emit_declared_podman_locks
		[[ -d /var/lib ]] && find /var/lib -xdev -path '*/.podman-compose/lifecycle.lock' -type f -print 2>/dev/null || true
	} | awk 'NF && !seen[$0]++'
}

clear_locks_from_emitter() {
	local emitter="$1" label="$2" path rc=0 emitted=0

	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		emitted=1
		clear_lock_path "$path" || rc=1
	done < <("$emitter" | awk 'NF && !seen[$0]++')
	[[ "$emitted" == "1" ]] || printf 'no %s locks found\n' "$label"
	return "$rc"
}

podman_users() {
	{
		if [[ -f /run/current-system/share/podman-compose/control-registry.json ]] && command -v jq >/dev/null 2>&1; then
			jq -r 'to_entries[]?.value.user // empty' /run/current-system/share/podman-compose/control-registry.json 2>/dev/null || true
		fi
		if [[ -d /run/user ]]; then
			for runtime in /run/user/[0-9]*; do
				[[ -d "$runtime" ]] || continue
				getent passwd "${runtime##*/}" | awk -F: '{print $1}'
			done
		fi
		if [[ -d /var/lib ]]; then
			for storage in /var/lib/*/.local/share/containers/storage; do
				[[ -d "$storage" ]] || continue
				stat -c %U "$storage" 2>/dev/null || true
			done
		fi
	} | awk 'NF && $0 != "UNKNOWN" && !seen[$0]++'
}

clean_podman_user_store() {
	local user="$1" home uid

	home="$(getent passwd "$user" | awk -F: '{print $6}')"
	uid="$(id -u "$user" 2>/dev/null || true)"
	[[ -n "$home" && -n "$uid" ]] || return 0

	HM_DRY_RUN="$dry" runuser -u "$user" -- env -i \
		HOME="$home" \
		USER="$user" \
		LOGNAME="$user" \
		SHELL=/run/current-system/sw/bin/bash \
		PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin \
		XDG_RUNTIME_DIR="/run/user/${uid}" \
		bash -s <<'USER_PODMAN_CLEAN'
set -Eeuo pipefail
dry="${HM_DRY_RUN:-1}"
if ! command -v podman >/dev/null 2>&1 || ! podman info >/dev/null 2>&1; then
	exit 0
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/host-manager-podman.XXXXXX")"
trap 'rm -rf "$work"' EXIT
vols="${work}/volumes"
hex="${work}/hex"
used="${work}/used"
unused="${work}/unused"
podman volume ls --format '{{.Name}}' | sort -u >"$vols"
grep -E '^[0-9a-f]{64}$' "$vols" >"$hex" || true
: >"$used"
ids="$(podman ps -aq || true)"
if [[ -n "$ids" ]]; then
	# shellcheck disable=SC2086
	podman inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' $ids 2>/dev/null | sort -u >"$used" || true
fi
comm -23 "$hex" "$used" >"$unused" || true
printf 'podman user=%s freeLocks=%s totalVolumes=%s anonymousVolumes=%s usedVolumes=%s unusedAnonymousVolumes=%s\n' \
	"$(id -un)" \
	"$(podman info --debug 2>/dev/null | awk '/freeLocks:/ {print $2; exit}')" \
	"$(wc -l <"$vols")" \
	"$(wc -l <"$hex")" \
	"$(wc -l <"$used")" \
	"$(wc -l <"$unused")"
if [[ "$dry" == "1" ]]; then
	sed 's/^/DRY volume rm /' "$unused"
	exit 0
fi
while IFS= read -r volume; do
	[[ -n "$volume" ]] || continue
	podman volume rm "$volume" || true
done <"$unused"
USER_PODMAN_CLEAN
}

clean_podman_volumes() {
	local user

	while IFS= read -r user; do
		[[ -n "$user" ]] || continue
		clean_podman_user_store "$user"
	done < <(podman_users)
}

case "$kind" in
nixbot)
	clear_locks_from_emitter emit_nixbot_locks nixbot
	;;
podman)
	clear_locks_from_emitter emit_podman_locks podman
	clean_podman_volumes
	;;
all)
	clear_locks_from_emitter emit_nixbot_locks nixbot
	clear_locks_from_emitter emit_podman_locks podman
	clean_podman_volumes
	;;
*)
	printf 'unsupported cleanup kind: %s\n' "$kind" >&2
	exit 2
	;;
esac
REMOTE_CLEAN
}

run_remote_clean_host() {
	local kind="$1" host="$2" script

	script="$(remote_lock_cleanup_script)"
	run_remote_root_script "$host" "$script" \
		HM_DRY_RUN="$DRY_RUN" \
		HM_FORCE_HELD="$FORCE_HELD" \
		HM_CLEAN_KIND="$kind"
}

run_remote_clean_deploy_host() {
	run_remote_clean_host all "$1"
}

run_remote_clean_nixbot_host() {
	run_remote_clean_host nixbot "$1"
}

run_remote_clean_podman_host() {
	run_remote_clean_host podman "$1"
}

run_remote_clean() {
	local kind="$1" target_label

	target_label="$(maintenance_target_label)"

	if [[ "$DRY_RUN" != "1" ]]; then
		confirm_or_die "Run ${kind} cleanup on ${target_label}?" "--yes"
	fi

	case "$kind" in
	all) run_for_target_hosts "clean:deploy" run_remote_clean_deploy_host ;;
	nixbot) run_for_target_hosts "clean:nixbot" run_remote_clean_nixbot_host ;;
	podman) run_for_target_hosts "clean:podman" run_remote_clean_podman_host ;;
	*) die "Unsupported cleanup kind: ${kind}" ;;
	esac
}

run_logs() {
	local script

	if [[ -n "$SERVICE_NAME" ]]; then
		run_service_action logs
		return
	fi

	script="$(
		cat <<'REMOTE_HOST_LOGS'
set -Eeuo pipefail
lines="${HM_LOG_LINES}"
since="${HM_LOG_SINCE}"
follow="${HM_LOG_FOLLOW}"

args=(--no-pager --lines "$lines")
[[ -z "$since" ]] || args+=(--since "$since")
[[ "$follow" != "1" ]] || args+=(-f)

printf 'host=%s journal=system\n' "$(hostname)" >&2
journalctl "${args[@]}"
REMOTE_HOST_LOGS
	)"
	run_remote_root_script "$HOST" "$script" \
		HM_LOG_LINES="$LOG_LINES" \
		HM_LOG_SINCE="$LOG_SINCE" \
		HM_LOG_FOLLOW="$LOG_FOLLOW"
}

remote_service_action_script() {
	cat <<'REMOTE_SERVICE'
set -Eeuo pipefail
service="${HM_LOG_SERVICE}"
action="${HM_SERVICE_ACTION}"
requested_user="${HM_LOG_USER}"
service_prefix="${HM_SERVICE_PREFIX}"
service_default_user="${HM_SERVICE_DEFAULT_USER}"
lines="${HM_LOG_LINES}"
since="${HM_LOG_SINCE}"
follow="${HM_LOG_FOLLOW}"
registry="/run/current-system/share/podman-compose/control-registry.json"
unit=""
user=""
if [[ -n "$service_prefix" && "$service" == "$service_prefix"* ]]; then
	prefixed_service="$service"
else
	prefixed_service="${service_prefix}${service}"
fi

if [[ -f "$registry" ]] && command -v jq >/dev/null 2>&1; then
	entry="$(jq -cer --arg service "$service" --arg prefixed_service "$prefixed_service" '
		.[$service]
		// .[$prefixed_service]
		// (to_entries[]? | select(
			.key == $service
			or .key == $prefixed_service
			or .value.serviceName == $service
			or .value.serviceName == $prefixed_service
		) | .value)
		// empty
	' "$registry" 2>/dev/null || true)"
	if [[ -n "$entry" ]]; then
		unit="$(jq -r '.unit // empty' <<<"$entry")"
		user="$(jq -r '.user // empty' <<<"$entry")"
	fi
fi

if [[ -z "$unit" ]]; then
	case "$service" in
	*.service | *.target)
		unit="$service"
		user="$requested_user"
		;;
	*)
		unit="${prefixed_service}.service"
		user="${requested_user:-$service_default_user}"
		;;
	esac
fi
if [[ -n "$requested_user" ]]; then
	user="$requested_user"
fi

run_unit_action_as_user() {
	local target_user="$1"
	shift
	home="$(getent passwd "$target_user" | awk -F: '{print $6}')"
	uid="$(id -u "$target_user")"
	runuser -u "$target_user" -- env -i \
		HOME="$home" \
		USER="$target_user" \
		LOGNAME="$target_user" \
		SHELL=/run/current-system/sw/bin/bash \
		PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin \
		XDG_RUNTIME_DIR="/run/user/${uid}" \
		"$@"
}

printf 'host=%s action=%s user=%s unit=%s\n' "$(hostname)" "$action" "${user:-system}" "$unit" >&2

case "$action" in
logs)
	args=(--no-pager --lines "$lines")
	[[ -z "$since" ]] || args+=(--since "$since")
	[[ "$follow" != "1" ]] || args+=(-f)
	if [[ -n "$user" && "$user" != "root" && "$user" != "system" ]]; then
		run_unit_action_as_user "$user" journalctl --user -u "$unit" "${args[@]}"
	else
		journalctl -u "$unit" "${args[@]}"
	fi
	;;
status)
	if [[ -n "$user" && "$user" != "root" && "$user" != "system" ]]; then
		run_unit_action_as_user "$user" systemctl --user status "$unit" --no-pager
	else
		systemctl status "$unit" --no-pager
	fi
	;;
start | stop | restart)
	if [[ "${HM_DRY_RUN}" == "1" ]]; then
		if [[ -n "$user" && "$user" != "root" && "$user" != "system" ]]; then
			printf 'DRY: systemctl --user %s %s as %s\n' "$action" "$unit" "$user"
		else
			printf 'DRY: systemctl %s %s\n' "$action" "$unit"
		fi
		exit 0
	fi
	if [[ -n "$user" && "$user" != "root" && "$user" != "system" ]]; then
		run_unit_action_as_user "$user" systemctl --user "$action" "$unit"
	else
		systemctl "$action" "$unit"
	fi
	;;
*)
	printf 'unsupported service action: %s\n' "$action" >&2
	exit 2
	;;
esac
REMOTE_SERVICE
}

run_service_action_on_host() {
	local service_action="$1" service_host="$2" service_prefix="$3" service_default_user="$4" script

	script="$(remote_service_action_script)"
	run_remote_root_script "$service_host" "$script" \
		HM_LOG_SERVICE="$SERVICE_NAME" \
		HM_SERVICE_ACTION="$service_action" \
		HM_DRY_RUN="$DRY_RUN" \
		HM_LOG_USER="$LOG_USER" \
		HM_SERVICE_PREFIX="$service_prefix" \
		HM_SERVICE_DEFAULT_USER="$service_default_user" \
		HM_LOG_LINES="$LOG_LINES" \
		HM_LOG_SINCE="$LOG_SINCE" \
		HM_LOG_FOLLOW="$LOG_FOLLOW"
}

run_service_action() {
	local service_action="$1" service_default_user="" service_host service_prefix="" stack=""
	local -a service_runtime=()
	local -a service_hosts=()
	local -a pids=()
	local pid rc=0

	if ! service_name_is_unit "$SERVICE_NAME"; then
		stack="${HOST_STACK:-$(default_service_stack)}"
		mapfile -t service_runtime < <(resolve_service_runtime_from_stack "$stack") ||
			die "Could not resolve service runtime defaults from stack: ${stack}"
		[[ "${#service_runtime[@]}" -eq 2 ]] || die "Invalid service runtime defaults from stack: ${stack}"
		service_prefix="${service_runtime[0]}"
		service_default_user="${service_runtime[1]}"
	fi

	if [[ -n "$HOST" ]]; then
		service_hosts=("$HOST")
	else
		if service_name_is_unit "$SERVICE_NAME"; then
			die "service ${service_action} for explicit unit names requires --host."
		fi
		mapfile -t service_hosts < <(resolve_service_hosts_from_stack "$SERVICE_NAME" "$stack") ||
			die "Could not resolve service from stack registry: ${SERVICE_NAME}"
		[[ "${#service_hosts[@]}" -gt 0 ]] || die "No hosts resolved for service: ${SERVICE_NAME}"
		for service_host in "${service_hosts[@]}"; do
			nixbot_host_registered "$service_host" || die "Resolved host is not in ${NIXBOT_FILE}: ${service_host}"
		done
	fi

	if [[ "$service_action" != "logs" && "$service_action" != "status" && "$DRY_RUN" != "1" ]]; then
		confirm_or_die "Run service ${service_action} for ${SERVICE_NAME} on ${service_hosts[*]}?" "--yes"
	fi

	if [[ "$service_action" == "logs" && "$LOG_FOLLOW" == "1" && "${#service_hosts[@]}" -gt 1 ]]; then
		for service_host in "${service_hosts[@]}"; do
			info "Following ${SERVICE_NAME} logs on ${service_host}"
			run_service_action_on_host "$service_action" "$service_host" "$service_prefix" "$service_default_user" &
			pids+=("$!")
		done
		for pid in "${pids[@]}"; do
			wait "$pid" || rc=1
		done
		return "$rc"
	fi

	for service_host in "${service_hosts[@]}"; do
		info "Running service ${service_action} for ${SERVICE_NAME} on ${service_host}"
		run_service_action_on_host "$service_action" "$service_host" "$service_prefix" "$service_default_user"
	done
}

print_install_commands() {
	if [[ -n "$STORE_DIR" ]]; then
		cat <<EOF
NIX_CONFIG=$(printf '%q' "$(store_nix_config "$STORE_DIR")") disko --mode destroy,format,mount --flake ${REPO_ROOT}#${HOST} --root-mountpoint ${ROOT_MOUNT} --yes-wipe-all-disks
nixos-install --option substituters $(printf '%q' "$(store_url "$STORE_DIR")") --option require-sigs false --flake ${REPO_ROOT}#${HOST} --root ${ROOT_MOUNT} --no-root-passwd
EOF
		return
	fi

	cat <<EOF
disko --mode destroy,format,mount --flake ${REPO_ROOT}#${HOST} --root-mountpoint ${ROOT_MOUNT} --yes-wipe-all-disks
nixos-install --flake ${REPO_ROOT}#${HOST} --root ${ROOT_MOUNT} --no-root-passwd
EOF
}

remove_attr_block() {
	local attr_name="$1"
	local input_file="$2"
	local output_file="$3"
	local attr_pattern

	attr_pattern="$(nix_attr_assignment_regex "$attr_name")"
	# Text-based Nix removal: braces inside strings/comments still affect depth.
	awk -v attr_pattern="$attr_pattern" '
		function delta(line, i, c, d) {
			d = 0
			for (i = 1; i <= length(line); i++) {
				c = substr(line, i, 1)
				if (c == "{") d++
				if (c == "}") d--
			}
			return d
		}

		!skipping && $0 ~ attr_pattern {
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

remove_line_matching() {
	local input_file="$1"
	local output_file="$2"
	local pattern="$3"

	awk -v pattern="$pattern" '$0 !~ pattern { print }' "$input_file" >"$output_file"
}

find_incus_parent_for_host() {
	local file

	for file in "${REPO_ROOT}"/hosts/*/incus.nix; do
		[[ -f "$file" ]] || continue
		if grep -Eq "$(nix_attr_assignment_regex "$HOST")" "$file"; then
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

	confirm_or_die "Delete host ${HOST} from repo config and machine secrets?" "--force" 1

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
		# Remove current machineIdentities entries and legacy direct registrations.
		remove_line_matching "$SECRETS_FILE" "$next_file" "$(nix_attr_assignment_regex "$HOST")[[:space:]]*[{][}];"
		mv "$next_file" "$SECRETS_FILE"
		remove_line_containing "$SECRETS_FILE" "$next_file" "./globals/machine/${HOST}.key.pub;"
		mv "$next_file" "$SECRETS_FILE"
		remove_line_containing "$SECRETS_FILE" "$next_file" "\"data/secrets/globals/machine/${HOST}.key.age\""
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
	trap cleanup_run_dir EXIT
	make_run_dir
	case "$ACTION" in
	generate | delete)
		acquire_mutation_lock
		validate_args
		;;
	*)
		validate_args
		;;
	esac

	case "$ACTION" in
	build) run_build ;;
	generate) run_generate ;;
	live-install) run_install ;;
	delete) delete_host ;;
	ssh) run_ssh ;;
	reboot) run_reboot ;;
	gc) run_gc ;;
	deploy-clean) run_remote_clean all ;;
	podman-clean) run_remote_clean podman ;;
	nixbot-clean) run_remote_clean nixbot ;;
	logs) run_logs ;;
	service-start) run_service_action start ;;
	service-stop) run_service_action stop ;;
	service-restart) run_service_action restart ;;
	service-status) run_service_action status ;;
	service-logs) run_service_action logs ;;
	esac
}

main "$@"

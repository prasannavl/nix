#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/host-manager.sh build --host HOST --store PATH
  scripts/host-manager.sh generate --host HOST [--system=none|live|incus] [options]
  scripts/host-manager.sh live-install --host HOST --wipe-disks [options]
  scripts/host-manager.sh delete --host HOST [--force|--yes]

The flake package also provides an equivalent host-manager binary.

Examples:
  scripts/host-manager.sh generate --system=live --host pvl-a1 \
    --disk /dev/disk/by-id/nvme-Lexar_SSD_ARES_2TB_QEC053R000846P2222 \
    --swap-size-mib 65536

  scripts/host-manager.sh build --host pvl-a1 --store /media/live-usb/nix-cache

  scripts/host-manager.sh live-install --host pvl-a1 --store /media/live-usb/nix-cache --wipe-disks

  scripts/host-manager.sh generate --host pvl-new --disk /dev/disk/by-id/nvme-...

  scripts/host-manager.sh generate --system=incus --incus-host pvl-x2 --host pvl-guest \
    --incus-ipv4 10.10.20.50

Actions:
  build                    Build a host system and copy the closure, flake
                           inputs, and host-manager runtime deps to --store.
  generate                 Create or update repo host config.
  live-install             Run live disko and nixos-install for an existing host.
  delete                   Remove host config, nixbot entry, age machine keys,
                           secret registration, and matching Incus instance
                           declaration.

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
  --store PATH             Local file binary cache for build/live-install.
  --boot-mode efi|uefi|bios
                           Physical boot layout. Default: efi
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
	REPO_ROOT="$(find_repo_root)"
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
	STORE_DIR=""
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
	SECRET_RUN_DIR=""
	STAGE_DIR=""
	MUTATION_LOCK_DIR=""
	STORE_LOCK_DIR=""
	GENERATED_HW_FILE=""
	EXTRACTED_HW_FILE=""
	GENERATED_SYS_FILE=""
	HOST_DIR=""
	HOSTS_DEFAULT_FILE="${REPO_ROOT}/hosts/default.nix"
	NIXBOT_FILE="${REPO_ROOT}/hosts/nixbot.nix"
	SECRETS_FILE="${REPO_ROOT}/data/secrets/default.nix"
	MACHINE_SECRET_DIR="${REPO_ROOT}/data/secrets/globals/machine"

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
		exec nix shell \
			--option substituters "$(store_url "$store_dir")" \
			--option require-sigs false \
			--inputs-from "${flake_path}" \
			"${runtime_pkgs[@]}" \
			-c env HOST_MANAGER_IN_NIX_SHELL=1 bash "${script_path}" "$@"
	fi

	exec nix shell --inputs-from "${flake_path}" "${runtime_pkgs[@]}" -c env HOST_MANAGER_IN_NIX_SHELL=1 bash "${script_path}" "$@"
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
		nixpkgs#nixos-install-tools
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
	[[ $# -gt 0 ]] || {
		usage
		exit 1
	}

	case "$1" in
	build | generate | live-install | delete)
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
	valid_host_name "$HOST" || die "--host must start and end with a letter or number, and use only letters, numbers, and hyphens."
	[[ "$HOST_SYSTEM" == "none" || "$HOST_SYSTEM" == "live" || "$HOST_SYSTEM" == "incus" ]] || die "--system must be one of: none, live, incus."
	[[ "$BOOT_MODE" == "efi" || "$BOOT_MODE" == "uefi" || "$BOOT_MODE" == "bios" ]] || die "--boot-mode must be one of: efi, uefi, bios."
	[[ "$SWAP_SIZE_MIB" =~ ^[0-9]+$ ]] || die "--swap-size-mib must be a non-negative integer."
	[[ -z "$INCUS_IPV4" ]] || valid_ipv4 "$INCUS_IPV4" || die "--incus-ipv4 must be an IPv4 address."
	[[ -z "$INCUS_HOST" ]] || valid_host_name "$INCUS_HOST" || die "--incus-host must start and end with a letter or number, and use only letters, numbers, and hyphens."
	[[ -z "$STORE_DIR" ]] || validate_store_dir "$STORE_DIR"
	[[ -z "$HARDWARE_CONFIG" || -f "$HARDWARE_CONFIG" ]] || die "Hardware config not found: $HARDWARE_CONFIG"
	HOST_DIR="${REPO_ROOT}/hosts/${HOST}"
	infer_disk_device
}

valid_host_name() {
	local name="$1"

	[[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

valid_incus_instance_name() {
	local name="$1"

	[[ "$name" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
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

	[[ -n "$INCUS_HOST" ]] || return
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
		if [[ "$HOST_SYSTEM" == "incus" ]]; then
			[[ -n "$INCUS_HOST" ]] || die "--system=incus requires --incus-host HOST."
			valid_incus_instance_name "$HOST" || die "--host must match Incus instance names for --system=incus: [a-z]([a-z0-9-]{0,61}[a-z0-9])?"
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
	register_staged_target "$target"
	printf '%s\n' "$staged"
}

replace_staged_file() {
	local source="$1"
	local target="$2"
	local staged

	staged="$(stage_file_for_write "$target")"
	mv "$source" "$staged"
}

copy_staged_file() {
	local source="$1"
	local target="$2"
	local staged

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
	grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*mkNixosSystem[[:space:]]*\\{" "$(target_read_path "$HOSTS_DEFAULT_FILE")"
}

has_nixbot_entry() {
	grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*\\{" "$(target_read_path "$NIXBOT_FILE")"
}

has_machine_secret_registration() {
	local source_file

	source_file="$(target_read_path "$SECRETS_FILE")"
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
	local target_file

	target_file="$(stage_file_for_write "${HOST_DIR}/default.nix")"
	cat >"$target_file" <<'EOF'
{...}: {
  imports = [
    ../../lib/profiles/all.nix
    ./sys.nix
  ];
}
EOF
	alejandra -q "$target_file"
}

write_lxc_host_default() {
	local default_file packages_file users_file

	default_file="$(stage_file_for_write "${HOST_DIR}/default.nix")"
	packages_file="$(stage_file_for_write "${HOST_DIR}/packages.nix")"
	users_file="$(stage_file_for_write "${HOST_DIR}/users.nix")"
	cat >"$default_file" <<'EOF'
{hostName, ...}: {
  imports = [
    ../../lib/profiles/lxc.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
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
	local source_file

	host_registered && return
	host_attr="$(nix_attr_key "$HOST")"

	cat >"$entry_file" <<EOF
  ${host_attr} = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "$(nix_escape "$HOST")";
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
	local staged_pub_file staged_age_file
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
	printf '%s\n' "$public_line" >"$(stage_file_for_write "$pub_file")"

	recipients_json="$(eval_staged_secrets)"
	mapfile -t recipients < <(jq -r --arg path "data/secrets/globals/machine/${HOST}.key.age" '.[$path].publicKeys[]? // empty' <<<"$recipients_json")
	[[ "${#recipients[@]}" -gt 0 ]] || die "No recipients configured for data/secrets/globals/machine/${HOST}.key.age"

	for recipient in "${recipients[@]}"; do
		age_args+=(-r "$recipient")
	done

	age "${age_args[@]}" -o "$(stage_file_for_write "$age_file")" "$tmp_key_file"
	rm -f -- "$tmp_key_file"
	info "Created machine age identity: data/secrets/globals/machine/${HOST}.key.age"
}

register_machine_secret() {
	local source_file
	local machine_key_file="${RUN_DIR}/secrets-default-machine-key.nix"
	local machine_secret_file="${RUN_DIR}/secrets-default-machine-secret.nix"
	local host_attr
	local changed="0"

	host_attr="$(nix_attr_key "$HOST")"
	source_file="$(target_read_path "$SECRETS_FILE")"
	if ! grep -Eq "$(nix_attr_assignment_regex "$HOST")[[:space:]]*./globals/machine/$(regex_escape "$HOST")\\.key\\.pub;" "$source_file"; then
		awk -v host="$HOST" -v host_attr="$host_attr" '
			{
				if ($0 ~ /^  machineKeyFiles = \{/) {
					in_keys = 1
				}
				if (in_keys && $0 ~ /^  \};/) {
					printf "    %s = ./globals/machine/%s.key.pub;\n", host_attr, host
					inserted = 1
					in_keys = 0
				}
				print
			}

			END {
				if (!inserted) {
					exit 1
				}
			}
		' "$source_file" >"$machine_key_file" || die "Could not register machine key file in ${SECRETS_FILE}."
		source_file="$machine_key_file"
		changed="1"
	fi

	if ! grep -Fq "\"data/secrets/globals/machine/${HOST}.key.age\"" "$source_file"; then
		awk -v host="$HOST" '
			{
				print
				if ($0 ~ /^    # Machines$/) {
					printf "    \"data/secrets/globals/machine/%s.key.age\".publicKeys = adminsWithNixbot;\n", host
					inserted = 1
				}
			}

			END {
				if (!inserted) {
					exit 1
				}
			}
		' "$source_file" >"$machine_secret_file" || die "Could not register machine secret in ${SECRETS_FILE}."
		source_file="$machine_secret_file"
		changed="1"
	fi

	if [[ "$changed" == "1" ]]; then
		alejandra -q "$source_file"
		copy_staged_file "$source_file" "$SECRETS_FILE"
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
      ageIdentityKey = "data/secrets/globals/machine/${HOST}.key.age";
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

	disko_import="../../lib/disko"

	{
		cat <<EOF
# Hardware and install-storage config. Generated by host-manager.
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
	local source_file

	host_attr="$(nix_attr_key "$HOST")"
	source_file="$(target_read_path "$parent_file")"
	if grep -Eq "$(nix_attr_assignment_regex "$HOST")" "$source_file"; then
		info "Incus instance already exists on ${INCUS_HOST}: ${HOST}"
		return
	fi

	cat >"$entry_file" <<EOF
      ${host_attr} = {
EOF
	if [[ -n "$INCUS_PROJECT" ]]; then
		cat >>"$entry_file" <<EOF
        project = "$(nix_escape "$INCUS_PROJECT")";
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
            source = "$(nix_escape "$HOST")";
            path = "/var/lib";
            removalPolicy = "delete";
          };
        };
      };
EOF

	insert_into_attrset "$entry_file" "$source_file" "$next_file" '^[[:space:]]*instances = [{]$' '^    [}];$'
	alejandra -q "$next_file"
	replace_staged_file "$next_file" "$parent_file"
	info "Added Incus instance ${HOST} to hosts/${INCUS_HOST}/incus.nix"
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
		# Remove key-file and encrypted-secret registrations in separate passes.
		remove_line_matching "$SECRETS_FILE" "$next_file" "$(nix_attr_assignment_regex "$HOST")[[:space:]]*./globals/machine/$(regex_escape "$HOST")\\.key\\.pub;"
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
	esac
}

main "$@"

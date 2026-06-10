#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs use $name variables inside single quotes.
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage:
  ${COMMAND_NAME} [--bundle NAME]
  ${COMMAND_NAME} --host HOST [--name NAME]
  ${COMMAND_NAME} --hosts HOST[,HOST...] [--name NAME]
  ${COMMAND_NAME} --target TARGET=HOST [--name NAME]
  ${COMMAND_NAME} --targets TARGET=HOST[,TARGET=HOST...] [--name NAME]
  ${COMMAND_NAME} --config FILE [--name NAME]
  ${COMMAND_NAME} --list

Build a repo live installer ISO with embedded offline-install target closures.

Defaults:
  --bundle all
  --minimal

Options:
  --bundle NAME         Build a declared bundle from nixosImages.installer.bundle.
  --minimal             Build the minimal NixOS live installer image.
  --gnome               Build the GNOME Calamares NixOS live installer image.
  --config FILE         Build targets from a Nix config file.
  --host HOST           Add one host as target HOST=HOST.
  --hosts A,B,C         Add comma-separated hosts as targets A=A,B=B,C=C.
  --target TARGET=HOST  Add one named install target backed by HOST.
  --targets A=H,B=H     Add comma-separated named install targets.
  --disk PATH           Override the selected single target's disko main disk.
  --disk TARGET=PATH    Override one target's disko main disk.
  --disks A=X,B=Y       Override comma-separated target disk specs.
  --fresh-ids           Generate fresh IDs for all selected targets.
  --fresh-ids A,B,C     Generate fresh IDs for comma-separated selected targets.
  --name NAME           Custom image name. Defaults to joined target names.
  --store-root DIR      Build in a custom local store rooted at DIR.
                        With --overlay, DIR is a disposable overlay store root.
                        Without --overlay, dependencies are duplicated into DIR.
  --overlay             Treat --store-root as a local overlay store.
  --print-overlay-mount Print the overlay mount command for --store-root.
  --system-store        Build in the normal configured Nix store. This is default.
  --out-link PATH       Optional Nix result symlink. Mostly useful with --system-store.
  --no-link             Do not create a result symlink.
  --dry-run             Print the nix build command without running it.
  --list                List declared bundles and installable target images.
  -h, --help            Show this help.

Target config file shape:
  {
    name = "installer-targets";
    installerProfile = "minimal"; # or "gnome"
    targets.example = {
      host = "example-host";
      disk = "/dev/disk/by-id/...";
      freshIds = true;
    };
  }

Examples:
  ${COMMAND_NAME}
  ${COMMAND_NAME} --bundle all
  ${COMMAND_NAME} --hosts=host-a,host-b --name workstations
  ${COMMAND_NAME} --target target-a=host-a --disk target-a=/dev/disk/by-id/nvme-... --fresh-ids target-a
  ${COMMAND_NAME} --config scripts/support/installer-targets.nix
EOF
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

info() {
	printf '%s\n' "$*" >&2
}

init_vars() {
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
	COMMAND_NAME="${INSTALLER_BUILDER_COMMAND:-lib/installer/builder.sh}"
	HOSTS=()
	TARGETS=()
	DISK_OVERRIDES=()
	FRESH_ID_OVERRIDES=()
	FRESH_ID_REQUESTS=()
	HOST_MODE=""
	TARGET_MODE=""
	DISK_MODE=""
	BUNDLE=""
	CONFIG_FILE=""
	INSTALLER_PROFILE=""
	IMAGE_NAME=""
	OUT_LINK=""
	NO_LINK="0"
	STORE_ROOT=""
	USE_OVERLAY_STORE="0"
	PRINT_OVERLAY_MOUNT="0"
	USE_SYSTEM_STORE="0"
	DRY_RUN="0"
	BUILD_SPEC_FILE=""
	CONFIG_RAW_FILE=""
	TEMP_FILES=()
}

cleanup() {
	local path

	if [ -n "$BUILD_SPEC_FILE" ]; then
		rm -f "$BUILD_SPEC_FILE"
	fi
	if [ -n "$CONFIG_RAW_FILE" ]; then
		rm -f "$CONFIG_RAW_FILE"
	fi
	for path in "${TEMP_FILES[@]}"; do
		rm -f "$path"
	done
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

set_installer_profile() {
	local profile="$1"

	case "$profile" in
	minimal | gnome) ;;
	*) die "Unsupported installer profile: $profile" ;;
	esac

	if [ -n "$INSTALLER_PROFILE" ] && [ "$INSTALLER_PROFILE" != "$profile" ]; then
		die "Use only one installer profile"
	fi

	INSTALLER_PROFILE="$profile"
}

effective_installer_profile() {
	printf '%s\n' "${INSTALLER_PROFILE:-minimal}"
}

split_csv() {
	local csv="$1"
	local item
	local old_ifs="$IFS"

	[ -n "$csv" ] || return
	IFS=,
	for item in $csv; do
		[ -n "$item" ] && printf '%s\n' "$item"
	done
	IFS="$old_ifs"
}

append_csv_hosts() {
	local csv="$1"
	local item

	[ -z "$TARGET_MODE" ] || die "Use either --host/--hosts or --target/--targets, not both"
	[ "$HOST_MODE" != "single" ] || die "Use either --host or --hosts, not both"
	[ -n "$csv" ] || die "--hosts requires a non-empty value"
	HOST_MODE="multi"
	while IFS= read -r item; do
		HOSTS+=("$item")
	done < <(split_csv "$csv")
}

append_single_host() {
	local host="$1"

	[ -z "$TARGET_MODE" ] || die "Use either --host/--hosts or --target/--targets, not both"
	[ "$HOST_MODE" != "multi" ] || die "Use either --host or --hosts, not both"
	[ "${#HOSTS[@]}" -eq 0 ] || die "--host accepts exactly one host; use --hosts for multiple hosts"
	[ -n "$host" ] || die "--host requires a non-empty value"
	HOST_MODE="single"
	HOSTS+=("$host")
}

append_target_spec() {
	local host spec target
	spec="$1"

	[[ "$spec" == *=* ]] || die "Target specs must use TARGET=HOST: $spec"
	target="${spec%%=*}"
	host="${spec#*=}"
	[ -n "$target" ] || die "Target spec has an empty target name: $spec"
	[ -n "$host" ] || die "Target spec has an empty host name: $spec"
	validate_name "$target"
	validate_name "$host"
	TARGETS+=("${target}=${host}")
}

append_csv_targets() {
	local csv="$1"
	local item

	[ -z "$HOST_MODE" ] || die "Use either --host/--hosts or --target/--targets, not both"
	[ "$TARGET_MODE" != "single" ] || die "Use either --target or --targets, not both"
	[ -n "$csv" ] || die "--targets requires a non-empty value"
	TARGET_MODE="multi"
	while IFS= read -r item; do
		append_target_spec "$item"
	done < <(split_csv "$csv")
}

append_single_target() {
	local spec="$1"

	[ -z "$HOST_MODE" ] || die "Use either --host/--hosts or --target/--targets, not both"
	[ "$TARGET_MODE" != "multi" ] || die "Use either --target or --targets, not both"
	[ "${#TARGETS[@]}" -eq 0 ] || die "--target accepts exactly one target; use --targets for multiple targets"
	[ -n "$spec" ] || die "--target requires a non-empty value"
	TARGET_MODE="single"
	append_target_spec "$spec"
}

append_disk_override() {
	local spec="$1"

	[ "$DISK_MODE" != "multi" ] || die "Use either --disk or --disks, not both"
	[ "${#DISK_OVERRIDES[@]}" -eq 0 ] || die "--disk accepts exactly one disk override; use --disks for multiple overrides"
	[ -n "$spec" ] || die "--disk requires a non-empty value"
	DISK_MODE="single"
	DISK_OVERRIDES+=("$spec")
}

append_csv_disk_overrides() {
	local csv="$1"
	local item

	[ "$DISK_MODE" != "single" ] || die "Use either --disk or --disks, not both"
	[ -n "$csv" ] || die "--disks requires a non-empty value"
	DISK_MODE="multi"
	while IFS= read -r item; do
		DISK_OVERRIDES+=("$item")
	done < <(split_csv "$csv")
}

append_fresh_ids() {
	local boot_part_uuid
	local luks_uuid
	local root_part_uuid
	local target="$1"

	validate_name "$target"
	boot_part_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
	root_part_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
	luks_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
	FRESH_ID_OVERRIDES+=("${target}=${boot_part_uuid},${root_part_uuid},${luks_uuid}")
}

append_csv_fresh_ids() {
	local csv="$1"
	local item

	[ -n "$csv" ] || die "--fresh-ids requires a non-empty value when used with ="
	while IFS= read -r item; do
		FRESH_ID_REQUESTS+=("$item")
	done < <(split_csv "$csv")
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--bundle)
			[ "$#" -ge 2 ] || die "--bundle requires a value"
			BUNDLE="$2"
			shift
			;;
		--bundle=*)
			BUNDLE="${1#--bundle=}"
			;;
		--minimal)
			set_installer_profile "minimal"
			;;
		--gnome)
			set_installer_profile "gnome"
			;;
		--config)
			[ "$#" -ge 2 ] || die "--config requires a value"
			CONFIG_FILE="$2"
			shift
			;;
		--config=*)
			CONFIG_FILE="${1#--config=}"
			;;
		--host)
			[ "$#" -ge 2 ] || die "--host requires a value"
			append_single_host "$2"
			shift
			;;
		--host=*)
			append_single_host "${1#--host=}"
			;;
		--hosts)
			[ "$#" -ge 2 ] || die "--hosts requires a value"
			append_csv_hosts "$2"
			shift
			;;
		--hosts=*)
			append_csv_hosts "${1#--hosts=}"
			;;
		--target)
			[ "$#" -ge 2 ] || die "--target requires a value"
			append_single_target "$2"
			shift
			;;
		--target=*)
			append_single_target "${1#--target=}"
			;;
		--targets)
			[ "$#" -ge 2 ] || die "--targets requires a value"
			append_csv_targets "$2"
			shift
			;;
		--targets=*)
			append_csv_targets "${1#--targets=}"
			;;
		--disk)
			[ "$#" -ge 2 ] || die "--disk requires a value"
			append_disk_override "$2"
			shift
			;;
		--disk=*)
			append_disk_override "${1#--disk=}"
			;;
		--disks)
			[ "$#" -ge 2 ] || die "--disks requires a value"
			append_csv_disk_overrides "$2"
			shift
			;;
		--disks=*)
			append_csv_disk_overrides "${1#--disks=}"
			;;
		--fresh-ids)
			if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then
				append_csv_fresh_ids "$2"
				shift
			else
				FRESH_ID_REQUESTS+=("__all__")
			fi
			;;
		--fresh-ids=*)
			append_csv_fresh_ids "${1#--fresh-ids=}"
			;;
		--name)
			[ "$#" -ge 2 ] || die "--name requires a value"
			IMAGE_NAME="$2"
			shift
			;;
		--name=*)
			IMAGE_NAME="${1#--name=}"
			;;
		--out-link)
			[ "$#" -ge 2 ] || die "--out-link requires a value"
			OUT_LINK="$2"
			NO_LINK="0"
			shift
			;;
		--out-link=*)
			OUT_LINK="${1#--out-link=}"
			NO_LINK="0"
			;;
		--no-link)
			NO_LINK="1"
			;;
		--store-root)
			[ "$#" -ge 2 ] || die "--store-root requires a value"
			STORE_ROOT="$2"
			shift
			;;
		--store-root=*)
			STORE_ROOT="${1#--store-root=}"
			;;
		--overlay)
			USE_OVERLAY_STORE="1"
			;;
		--print-overlay-mount)
			PRINT_OVERLAY_MOUNT="1"
			;;
		--system-store)
			USE_SYSTEM_STORE="1"
			;;
		--dry-run)
			DRY_RUN="1"
			;;
		--list)
			list_images
			exit 0
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

list_images() {
	require_cmds nix
	info "Installable default target images:"
	nix eval --json "${REPO_ROOT}#nixosImages.installer" --apply 'x: builtins.filter (name: name != "bundle") (builtins.attrNames x)'
	info "Declared bundles:"
	nix eval --json "${REPO_ROOT}#nixosImages.installer.bundle" --apply 'x: builtins.filter (name: name != "profiles") (builtins.attrNames x)'
	info "Declared bundle profiles:"
	nix eval --json "${REPO_ROOT}#nixosImages.installer.bundle.profiles" --apply 'x: builtins.attrNames x'
}

list_installable_hosts_raw() {
	nix eval --raw "${REPO_ROOT}#nixosImages.installer" --apply 'x: builtins.concatStringsSep "\n" (builtins.filter (name: name != "bundle") (builtins.attrNames x))'
}

json_string() {
	local value="$1"

	jq -Rn --arg value "$value" '$value'
}

resolve_path() {
	local path="$1"

	case "$path" in
	/*) printf '%s\n' "$path" ;;
	*) printf '%s/%s\n' "$PWD" "$path" ;;
	esac
}

make_temp_json() {
	local path

	path="$(mktemp "${REPO_ROOT}/tmp/installer-json.XXXXXX.json")"
	TEMP_FILES+=("$path")
	printf '%s\n' "$path"
}

rewrite_json_file() {
	local file="$1"
	local tmp_file
	shift

	tmp_file="$(make_temp_json)"
	jq "$@" "$file" >"$tmp_file"
	mv "$tmp_file" "$file"
}

validate_hosts() {
	local host

	for host in "${HOSTS[@]}"; do
		validate_name "$host"
	done
}

validate_target_specs() {
	local host
	local seen='{}'
	local spec
	local target

	for spec in "${TARGETS[@]}"; do
		target="${spec%%=*}"
		host="${spec#*=}"
		validate_name "$target"
		validate_name "$host"
		if jq -e --arg target "$target" '.[$target] == true' <<<"$seen" >/dev/null; then
			die "Duplicate target: $target"
		fi
		seen="$(jq -c --arg target "$target" '. + {($target): true}' <<<"$seen")"
	done
}

validate_unique_selected_targets() {
	local seen='{}'
	local target

	while IFS= read -r target || [ -n "$target" ]; do
		[ -n "$target" ] || continue
		if jq -e --arg target "$target" '.[$target] == true' <<<"$seen" >/dev/null; then
			die "Duplicate selected target: $target"
		fi
		seen="$(jq -c --arg target "$target" '. + {($target): true}' <<<"$seen")"
	done < <(selected_target_names)
}

validate_unique_specs() {
	local label="$1"
	local seen='{}'
	local spec
	local target
	shift

	for spec in "$@"; do
		[ -n "$spec" ] || continue
		target="${spec%%=*}"
		if jq -e --arg target "$target" '.[$target] == true' <<<"$seen" >/dev/null; then
			die "Duplicate ${label}: $target"
		fi
		seen="$(jq -c --arg target "$target" '. + {($target): true}' <<<"$seen")"
	done
}

explicit_selected_target_names() {
	local host
	local spec

	if [ "${#TARGETS[@]}" -gt 0 ]; then
		for spec in "${TARGETS[@]}"; do
			printf '%s\n' "${spec%%=*}"
		done
	elif [ "${#HOSTS[@]}" -gt 0 ]; then
		for host in "${HOSTS[@]}"; do
			printf '%s\n' "$host"
		done
	fi
}

selected_target_names() {
	if [ "${#TARGETS[@]}" -gt 0 ] || [ "${#HOSTS[@]}" -gt 0 ]; then
		explicit_selected_target_names
	else
		list_installable_hosts_raw
	fi
}

selected_target_entries() {
	local host
	local spec

	if [ "${#TARGETS[@]}" -gt 0 ]; then
		for spec in "${TARGETS[@]}"; do
			printf '%s\n' "$spec"
		done
	elif [ "${#HOSTS[@]}" -gt 0 ]; then
		for host in "${HOSTS[@]}"; do
			printf '%s=%s\n' "$host" "$host"
		done
	else
		while IFS= read -r host || [ -n "$host" ]; do
			[ -n "$host" ] && printf '%s=%s\n' "$host" "$host"
		done < <(list_installable_hosts_raw)
	fi
}

selected_target_for_bare_override() {
	local names=()

	while IFS= read -r name; do
		[ -n "$name" ] && names+=("$name")
	done < <(explicit_selected_target_names)

	if [ "${#names[@]}" -ne 1 ]; then
		die "Bare --disk requires exactly one --host or --target. Use TARGET=PATH for multi-target images."
	fi

	printf '%s\n' "${names[0]}"
}

has_fresh_id_override() {
	local spec
	local target="$1"

	for spec in "${FRESH_ID_OVERRIDES[@]}"; do
		[ "${spec%%=*}" = "$target" ] && return 0
	done

	return 1
}

append_fresh_ids_once() {
	local target="$1"

	if has_fresh_id_override "$target"; then
		return
	fi

	append_fresh_ids "$target"
}

resolve_fresh_id_requests() {
	local request
	local selected_targets=()
	local target

	if [ "${#FRESH_ID_REQUESTS[@]}" -eq 0 ]; then
		return
	fi

	while IFS= read -r target || [ -n "$target" ]; do
		[ -n "$target" ] && selected_targets+=("$target")
	done < <(selected_target_names)

	for request in "${FRESH_ID_REQUESTS[@]}"; do
		if [ "$request" = "__all__" ]; then
			for target in "${selected_targets[@]}"; do
				append_fresh_ids_once "$target"
			done
		else
			append_fresh_ids_once "$request"
		fi
	done
}

validate_disk_overrides() {
	local normalized=()
	local path
	local spec
	local target

	for spec in "${DISK_OVERRIDES[@]}"; do
		if [[ "$spec" == *=* ]]; then
			target="${spec%%=*}"
			path="${spec#*=}"
		else
			[ "$DISK_MODE" != "multi" ] || die "--disks entries must be TARGET=PATH"
			target="$(selected_target_for_bare_override)"
			path="$spec"
			spec="${target}=${path}"
		fi
		validate_name "$target"
		[ -n "$path" ] || die "Empty disk override for target: $target"
		normalized+=("$spec")
	done

	DISK_OVERRIDES=("${normalized[@]}")
}

validate_fresh_id_overrides() {
	local ids
	local spec
	local target
	local uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

	for spec in "${FRESH_ID_OVERRIDES[@]}"; do
		target="${spec%%=*}"
		ids="${spec#*=}"
		validate_name "$target"
		[[ "$ids" =~ ^${uuid_re},${uuid_re},${uuid_re}$ ]] || die "Invalid fresh ID spec for target: $target"
	done
}

target_is_selected() {
	local selected
	local target="$1"

	while IFS= read -r selected || [ -n "$selected" ]; do
		[ "$selected" = "$target" ] && return 0
	done < <(selected_target_names)

	return 1
}

validate_overrides_target_selected() {
	local spec
	local target

	for spec in "${DISK_OVERRIDES[@]}" "${FRESH_ID_OVERRIDES[@]}"; do
		[ -n "$spec" ] || continue
		target="${spec%%=*}"
		if ! target_is_selected "$target"; then
			die "Override provided for non-selected target: $target"
		fi
	done
}

disk_override_for_target() {
	local spec
	local target="$1"

	for spec in "${DISK_OVERRIDES[@]}"; do
		if [ "${spec%%=*}" = "$target" ]; then
			printf '%s\n' "${spec#*=}"
			return
		fi
	done
}

fresh_id_override_for_target() {
	local spec
	local target="$1"

	for spec in "${FRESH_ID_OVERRIDES[@]}"; do
		if [ "${spec%%=*}" = "$target" ]; then
			printf '%s\n' "${spec#*=}"
			return
		fi
	done
}

store_url_for_root() {
	local root="$1"

	printf 'local?root=%s\n' "$root"
}

overlay_store_url_for_root() {
	local root="$1"

	printf 'local-overlay://?root=%s/root&lower-store=auto&upper-layer=%s/upper\n' "$root" "$root"
}

overlay_store_mountpoint() {
	local root="$1"

	printf '%s/root/nix/store\n' "$root"
}

print_overlay_mount_command() {
	local root="$1"
	local mountpoint

	mountpoint="$(overlay_store_mountpoint "$root")"
	cat <<EOF
mkdir -p ${root@Q}/root/nix/store ${root@Q}/upper ${root@Q}/work
mount -t overlay overlay \\
  -o lowerdir=/nix/store \\
  -o upperdir=${root@Q}/upper \\
  -o workdir=${root@Q}/work \\
  ${mountpoint@Q}
EOF
}

ensure_overlay_store_mount() {
	local mountpoint
	local root="$1"

	mountpoint="$(overlay_store_mountpoint "$root")"
	mkdir -p "$mountpoint" "$root/upper" "$root/work"
	if ! mountpoint -q "$mountpoint"; then
		printf 'Overlay store is not mounted: %s\n' "$mountpoint" >&2
		printf 'Run this as root first:\n' >&2
		print_overlay_mount_command "$root" >&2
		exit 1
	fi
}

physical_store_path() {
	local store_path="$1"
	local store_root="$2"

	if [ -n "$store_root" ] && [[ "$store_path" == /nix/store/* ]]; then
		printf '%s%s\n' "$store_root" "$store_path"
	else
		printf '%s\n' "$store_path"
	fi
}

find_iso_file() {
	local output_path="$1"
	local iso_files=()
	local iso_file

	if [ -f "$output_path" ] && [[ "$output_path" == *.iso ]]; then
		printf '%s\n' "$output_path"
		return
	fi

	while IFS= read -r iso_file || [ -n "$iso_file" ]; do
		[ -n "$iso_file" ] && iso_files+=("$iso_file")
	done < <(find "$output_path" -maxdepth 3 -type f -name '*.iso' | sort)

	if [ "${#iso_files[@]}" -ne 1 ]; then
		die "Expected exactly one ISO in build output $output_path, found ${#iso_files[@]}"
	fi

	printf '%s\n' "${iso_files[0]}"
}

default_custom_name() {
	local names=()
	local old_ifs="$IFS"
	local target

	while IFS= read -r target || [ -n "$target" ]; do
		[ -n "$target" ] && names+=("$target")
	done < <(selected_target_names)

	IFS=-
	printf '%s\n' "${names[*]}"
	IFS="$old_ifs"
}

write_custom_spec() {
	local boot_part_uuid
	local disk
	local entries=()
	local has_disk
	local has_ids
	local host
	local ids
	local ids_json
	local luks_uuid
	local profile
	local root_part_uuid
	local spec
	local spec_file="$1"
	local target

	while IFS= read -r spec || [ -n "$spec" ]; do
		[ -n "$spec" ] && entries+=("$spec")
	done < <(selected_target_entries)

	profile="$(effective_installer_profile)"
	jq -n \
		--arg installerName "$IMAGE_NAME" \
		--arg installerProfile "$profile" \
		'{installerName: $installerName, installerProfile: $installerProfile, targets: {}}' >"$spec_file"

	for spec in "${entries[@]}"; do
		target="${spec%%=*}"
		host="${spec#*=}"
		disk="$(disk_override_for_target "$target")"
		ids="$(fresh_id_override_for_target "$target")"
		has_disk=false
		has_ids=false
		ids_json=null
		if [ -n "$disk" ]; then
			has_disk=true
		fi
		if [ -n "$ids" ]; then
			has_ids=true
			IFS=, read -r boot_part_uuid root_part_uuid luks_uuid <<<"$ids"
			ids_json="$(
				jq -n \
					--arg boot "$boot_part_uuid" \
					--arg root "$root_part_uuid" \
					--arg luks "$luks_uuid" \
					'{bootPartUuid: $boot, rootPartUuid: $root, luksUuid: $luks}'
			)"
		fi

		rewrite_json_file "$spec_file" \
			--arg target "$target" \
			--arg host "$host" \
			--arg disk "$disk" \
			--argjson hasDisk "$has_disk" \
			--argjson hasIds "$has_ids" \
			--argjson ids "$ids_json" \
			'.targets[$target] =
				(
					{host: $host}
					+ (if $hasDisk then {disk: $disk} else {} end)
					+ (if $hasIds then {ids: $ids} else {} end)
				)'
	done
}

config_default_name() {
	local file="$1"
	local name

	name="$(basename "$file")"
	name="${name%.nix}"
	name="${name%.json}"
	printf '%s\n' "$name"
}

normalize_config_spec() {
	local config_file
	local spec_file
	config_file="$(resolve_path "$1")"
	spec_file="$2"

	[ -r "$config_file" ] || die "Config file is not readable: $config_file"
	CONFIG_RAW_FILE="$(mktemp "${REPO_ROOT}/tmp/installer-config.XXXXXX.json")"
	nix eval --json --file "$config_file" >"$CONFIG_RAW_FILE"
	jq '
		{
			installerName: (.installerName // .name // ""),
			installerProfile: (.installerProfile // .profile // "minimal"),
			targets: (.targets // {})
		}
		| if (.installerProfile | type) != "string" then
			error("installerProfile must be a string")
		elif (.installerProfile != "minimal" and .installerProfile != "gnome") then
			error("installerProfile must be minimal or gnome")
		else
			.
		end
		| if (.targets | type) != "object" then
			error("installer config targets must be an attrset")
		else
			.
		end
		| .targets |= with_entries(
			if (.value | type) != "object" then
				error("installer target " + .key + " must be an attrset")
			elif (.value.host == null or (.value.host | type) != "string" or .value.host == "") then
				error("installer target " + .key + " must set a non-empty string host")
			elif (.value.disk != null and (.value.disk | type) != "string") then
				error("installer target " + .key + " disk must be a string when set")
			elif ((.value.freshIds // false) | type) != "boolean" then
				error("installer target " + .key + " freshIds must be a boolean when set")
			elif (.value.ids != null and (.value.ids | type) != "object") then
				error("installer target " + .key + " ids must be an attrset when set")
			elif (.value.ids != null and (.value.freshIds // false)) then
				error("installer target " + .key + " cannot set both ids and freshIds")
			else
				{
					key: .key,
					value: {
						host: .value.host,
						disk: (.value.disk // null),
						ids: (.value.ids // null),
						freshIds: (.value.freshIds // false)
					}
				}
			end
		)
	' "$CONFIG_RAW_FILE" >"$spec_file"
}

apply_config_fresh_ids() {
	local boot_part_uuid
	local luks_uuid
	local root_part_uuid
	local spec_file="$1"
	local target
	local tmp_file

	while IFS= read -r target || [ -n "$target" ]; do
		boot_part_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
		root_part_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
		luks_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
		rewrite_json_file "$spec_file" \
			--arg target "$target" \
			--arg boot "$boot_part_uuid" \
			--arg root "$root_part_uuid" \
			--arg luks "$luks_uuid" \
			'.targets[$target].ids = {bootPartUuid: $boot, rootPartUuid: $root, luksUuid: $luks}'
	done < <(jq -r '.targets | to_entries[] | select(.value.freshIds == true) | .key' "$spec_file")

	rewrite_json_file "$spec_file" '.targets |= with_entries(.value |= del(.freshIds))'
}

finalize_config_spec() {
	local config_name
	local host
	local spec_file="$1"
	local target

	if [ -n "$IMAGE_NAME" ]; then
		rewrite_json_file "$spec_file" --arg name "$IMAGE_NAME" '.installerName = $name'
	fi
	if [ -n "$INSTALLER_PROFILE" ]; then
		rewrite_json_file "$spec_file" --arg profile "$INSTALLER_PROFILE" '.installerProfile = $profile'
	fi

	IMAGE_NAME="$(jq -r '.installerName // ""' "$spec_file")"
	if [ -z "$IMAGE_NAME" ]; then
		config_name="$(config_default_name "$CONFIG_FILE")"
		IMAGE_NAME="$config_name"
		rewrite_json_file "$spec_file" --arg name "$IMAGE_NAME" '.installerName = $name'
	fi

	validate_name "$IMAGE_NAME"
	jq -e '.installerProfile == "minimal" or .installerProfile == "gnome"' "$spec_file" >/dev/null ||
		die "Installer config installerProfile must be minimal or gnome"
	jq -e '(.targets | type == "object") and (.targets | length > 0)' "$spec_file" >/dev/null ||
		die "Installer config must select at least one target"

	while IFS= read -r target || [ -n "$target" ]; do
		validate_name "$target"
	done < <(jq -r '.targets | keys[]' "$spec_file")

	while IFS= read -r host || [ -n "$host" ]; do
		validate_name "$host"
	done < <(jq -r '.targets[].host' "$spec_file")

	jq -e '
		def uuid: test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
		. as $root
		| ([
			$root.targets
			| to_entries[]
			| select(.value.ids != null)
			| select(
				(.value.ids.bootPartUuid // "" | uuid) and
				(.value.ids.rootPartUuid // "" | uuid) and
				(.value.ids.luksUuid // "" | uuid)
			)
		] | length) == ([$root.targets | to_entries[] | select(.value.ids != null)] | length)
	' "$spec_file" >/dev/null || die "Installer config has invalid ids; expected bootPartUuid/rootPartUuid/luksUuid"
}

prepare_config_spec() {
	local spec_file="$1"

	require_cmds nix jq uuidgen tr
	[ -z "$BUNDLE" ] || die "Use either --config or --bundle, not both"
	[ "${#HOSTS[@]}" -eq 0 ] || die "Use either --config or --host/--hosts, not both"
	[ "${#TARGETS[@]}" -eq 0 ] || die "Use either --config or --target/--targets, not both"
	[ "${#DISK_OVERRIDES[@]}" -eq 0 ] || die "Use either --config or --disk/--disks, not both"
	[ "${#FRESH_ID_REQUESTS[@]}" -eq 0 ] || die "Use either --config or --fresh-ids, not both"

	normalize_config_spec "$CONFIG_FILE" "$spec_file"
	apply_config_fresh_ids "$spec_file"
	finalize_config_spec "$spec_file"
}

prepare_cli_custom_spec() {
	local spec_file="$1"

	require_cmds jq uuidgen tr
	validate_hosts
	validate_target_specs
	validate_disk_overrides
	resolve_fresh_id_requests
	validate_fresh_id_overrides
	validate_unique_selected_targets
	validate_unique_specs "disk override" "${DISK_OVERRIDES[@]}"
	validate_unique_specs "fresh ID override" "${FRESH_ID_OVERRIDES[@]}"
	validate_overrides_target_selected
	IMAGE_NAME="${IMAGE_NAME:-$(default_custom_name)}"
	validate_name "$IMAGE_NAME"
	write_custom_spec "$spec_file"
}

build_installer() {
	local build_output
	local installable
	local installer_profile
	local iso_path
	local physical_output
	local spec_file=""
	local store_root=""
	local -a cmd=()
	local use_custom_expr="0"

	require_cmds nix
	installer_profile="$(effective_installer_profile)"
	if [ "$USE_OVERLAY_STORE" = "1" ] && [ -z "$STORE_ROOT" ]; then
		die "--overlay requires --store-root"
	fi
	if [ "$PRINT_OVERLAY_MOUNT" = "1" ] && [ "$USE_OVERLAY_STORE" != "1" ]; then
		die "--print-overlay-mount requires --overlay --store-root DIR"
	fi
	[ "$USE_SYSTEM_STORE" != "1" ] || [ -z "$STORE_ROOT" ] || die "Use either --system-store or --store-root, not both"
	if [ -n "$STORE_ROOT" ] && [ -n "$OUT_LINK" ]; then
		die "Use --system-store with --out-link; custom store builds print the ISO path under the custom store root instead"
	fi
	if [ -n "$CONFIG_FILE" ]; then
		use_custom_expr="1"
	elif [ "${#HOSTS[@]}" -gt 0 ] && [ -n "$BUNDLE" ]; then
		die "Use either --bundle or --host/--hosts, not both"
	elif [ "${#TARGETS[@]}" -gt 0 ] && [ -n "$BUNDLE" ]; then
		die "Use either --bundle or --target/--targets, not both"
	elif [ -n "$BUNDLE" ] && { [ "${#DISK_OVERRIDES[@]}" -gt 0 ] || [ "${#FRESH_ID_REQUESTS[@]}" -gt 0 ]; }; then
		die "Build-time overrides require --host/--hosts, --target/--targets, or the default all-host custom image; do not combine them with --bundle"
	elif [ "${#HOSTS[@]}" -eq 0 ] && [ "${#TARGETS[@]}" -eq 0 ] && [ "${#DISK_OVERRIDES[@]}" -eq 0 ] && [ "${#FRESH_ID_REQUESTS[@]}" -eq 0 ]; then
		BUNDLE="${BUNDLE:-all}"
		validate_name "$BUNDLE"
		IMAGE_NAME="${IMAGE_NAME:-$BUNDLE}"
		if [ "$installer_profile" = "minimal" ]; then
			installable="${REPO_ROOT}#nixosImages.installer.bundle.${BUNDLE}.config.system.build.isoImage"
		else
			installable="${REPO_ROOT}#nixosImages.installer.bundle.profiles.${installer_profile}.${BUNDLE}.config.system.build.isoImage"
		fi
	else
		use_custom_expr="1"
	fi

	if [ "$use_custom_expr" = "1" ]; then
		if [ -n "$BUNDLE" ]; then
			die "Build-time overrides require --host/--hosts, --target/--targets, or the default all-host custom image; do not combine with --bundle"
		fi
		mkdir -p "${REPO_ROOT}/tmp"
		spec_file="$(mktemp "${REPO_ROOT}/tmp/installer-image.XXXXXX.json")"
		BUILD_SPEC_FILE="$spec_file"
		if [ -n "$CONFIG_FILE" ]; then
			prepare_config_spec "$spec_file"
		else
			prepare_cli_custom_spec "$spec_file"
		fi
		installer_profile="$(jq -r '.installerProfile // "minimal"' "$spec_file")"
		installable="${REPO_ROOT}/lib/installer/build-image.nix"
	fi

	if [ "$USE_SYSTEM_STORE" = "1" ] && [ -z "$OUT_LINK" ] && [ "$NO_LINK" != "1" ]; then
		OUT_LINK="${REPO_ROOT}/result-installer-${IMAGE_NAME}"
	fi
	if [ "$USE_SYSTEM_STORE" != "1" ] && [ -z "$STORE_ROOT" ] && [ -z "$OUT_LINK" ] && [ "$NO_LINK" != "1" ]; then
		OUT_LINK="${REPO_ROOT}/result-installer-${IMAGE_NAME}"
	fi
	if [ -n "$STORE_ROOT" ]; then
		NO_LINK="1"
		store_root="$(resolve_path "$STORE_ROOT")"
	fi
	if [ "$PRINT_OVERLAY_MOUNT" = "1" ]; then
		print_overlay_mount_command "$store_root"
		return
	fi

	cmd=(nix build --print-out-paths)
	if [ "$USE_OVERLAY_STORE" = "1" ]; then
		cmd+=(--extra-experimental-features local-overlay-store)
		cmd+=(--store "$(overlay_store_url_for_root "$store_root")")
	elif [ -n "$store_root" ]; then
		cmd+=(--store "$(store_url_for_root "$store_root")")
	fi
	if [ "$NO_LINK" = "1" ]; then
		cmd+=(--no-link)
	else
		cmd+=(--out-link "$OUT_LINK")
	fi

	if [ "$use_custom_expr" = "1" ]; then
		cmd+=(--file "$installable" --argstr repoRoot "$REPO_ROOT" --argstr specFile "$spec_file")
	else
		cmd+=("$installable")
	fi

	printf 'Building installer image: %s (%s)\n' "$IMAGE_NAME" "$installer_profile" >&2
	printf 'Command:' >&2
	shell_quote_args "${cmd[@]}" >&2

	if [ "$DRY_RUN" = "1" ]; then
		if [ -n "$spec_file" ]; then
			rm -f "$spec_file"
			BUILD_SPEC_FILE=""
			printf 'Dry run removed temporary spec file.\n' >&2
		fi
		if [ "$USE_OVERLAY_STORE" = "1" ]; then
			printf 'Dry run would build in local overlay store root: %s\n' "$store_root" >&2
		elif [ -n "$store_root" ]; then
			printf 'Dry run would build in local store root: %s\n' "$store_root" >&2
		else
			printf 'Dry run would build in the configured Nix store.\n' >&2
		fi
		return
	fi

	if [ "$USE_OVERLAY_STORE" = "1" ]; then
		ensure_overlay_store_mount "$store_root"
	elif [ -n "$store_root" ]; then
		mkdir -p "$store_root"
	fi
	build_output="$("${cmd[@]}")"
	printf '%s\n' "$build_output"
	if [ "$USE_OVERLAY_STORE" = "1" ]; then
		physical_output="$(physical_store_path "$build_output" "$store_root/root")"
	else
		physical_output="$(physical_store_path "$build_output" "$store_root")"
	fi
	iso_path="$(find_iso_file "$physical_output")"

	if [ -n "$spec_file" ]; then
		rm -f "$spec_file"
		BUILD_SPEC_FILE=""
	fi

	if [ -n "$OUT_LINK" ]; then
		printf 'Result link: %s\n' "$OUT_LINK" >&2
	fi
	if [ "$USE_OVERLAY_STORE" = "1" ]; then
		printf 'Local overlay store root: %s\n' "$store_root" >&2
	elif [ -n "$store_root" ]; then
		printf 'Local store root: %s\n' "$store_root" >&2
	fi
	printf 'ISO path: %s\n' "$iso_path" >&2
}

main() {
	init_vars
	trap cleanup EXIT
	parse_args "$@"
	build_installer
}

main "$@"

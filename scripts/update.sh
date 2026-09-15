#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: update.sh [options]

Runs all repo maintenance update scripts:
  flake lock updates
  external sources under lib/ext/* and pkgs/ext/*
  Podman Compose image pin updates

Options:
  --skip-flake          Do not update flake locks.
  --only-flake          Only update flake locks.
  --skip-ext            Do not process lib/ext source units.
  --only-ext            Only process lib/ext source units.
  --skip-ext-NAME       Skip lib/ext/NAME. May be repeated.
  --only-ext-NAME       Only process lib/ext/NAME. May be repeated.
  --skip-pkgs-ext       Do not process pkgs/ext source units.
  --only-pkgs-ext       Only process pkgs/ext source units.
  --skip-images         Do not process Podman Compose image pins.
  --only-images         Only process Podman Compose image pins.
  --jobs N              Parallel lookup jobs. Default: 16.
  --ansi                Always use ANSI styling for report updates.
  --color[=WHEN]        Status styling: auto, always, never. Default: auto.
  --report              Print version status without updating.
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	LIB_EXT_DIR="${REPO_ROOT}/lib/ext"
	PKGS_EXT_DIR="${REPO_ROOT}/pkgs/ext"
	SKIP_FLAKE=0
	ONLY_FLAKE=0
	SKIP_EXT=0
	ONLY_EXT=0
	SKIP_PKGS_EXT=0
	ONLY_PKGS_EXT=0
	SKIP_IMAGES=0
	ONLY_IMAGES=0
	RUN_FLAKES=1
	RUN_EXT=1
	RUN_PKGS_EXT=1
	RUN_IMAGES=1
	REPORT=0
	REPORT_JOBS=16
	COLOR_MODE="auto"
	ONLY_EXT_NAMES=()
	SKIP_EXT_NAMES=()
	REPORT_FAILURES=()
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			usage
			exit 0
			;;
		--skip-flake)
			SKIP_FLAKE=1
			;;
		--only-flake)
			ONLY_FLAKE=1
			;;
		--skip-ext)
			SKIP_EXT=1
			;;
		--only-ext)
			ONLY_EXT=1
			;;
		--skip-pkgs-ext)
			SKIP_PKGS_EXT=1
			;;
		--only-pkgs-ext)
			ONLY_PKGS_EXT=1
			;;
		--skip-images)
			SKIP_IMAGES=1
			;;
		--only-images)
			ONLY_IMAGES=1
			;;
		--jobs | -j)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REPORT_JOBS="$2"
			shift 2
			continue
			;;
		--ansi)
			COLOR_MODE="always"
			;;
		--color)
			COLOR_MODE="always"
			;;
		--color=*)
			COLOR_MODE="${1#--color=}"
			;;
		--skip-ext-*)
			SKIP_EXT_NAMES+=("${1#--skip-ext-}")
			;;
		--only-ext-*)
			ONLY_EXT_NAMES+=("${1#--only-ext-}")
			;;
		--report)
			REPORT=1
			;;
		*)
			die "Unknown argument: $1"
			;;
		esac
		shift
	done
}

contains_name() {
	local needle="$1"
	shift

	local name
	for name in "$@"; do
		[[ "$name" == "$needle" ]] && return 0
	done
	return 1
}

normalize_options() {
	if ((SKIP_FLAKE && ONLY_FLAKE)); then
		die "--skip-flake cannot be combined with --only-flake"
	fi
	if ((SKIP_EXT && (ONLY_EXT || ${#ONLY_EXT_NAMES[@]} > 0))); then
		die "--skip-ext cannot be combined with --only-ext or --only-ext-NAME"
	fi
	if ((ONLY_FLAKE && (ONLY_EXT || ${#ONLY_EXT_NAMES[@]} > 0))); then
		die "--only-flake cannot be combined with --only-ext or --only-ext-NAME"
	fi
	if ((SKIP_IMAGES && ONLY_IMAGES)); then
		die "--skip-images cannot be combined with --only-images"
	fi
	if ((ONLY_IMAGES && (ONLY_FLAKE || ONLY_EXT || ${#ONLY_EXT_NAMES[@]} > 0))); then
		die "--only-images cannot be combined with --only-flake, --only-ext, or --only-ext-NAME"
	fi
	if ((SKIP_PKGS_EXT && ONLY_PKGS_EXT)); then
		die "--skip-pkgs-ext cannot be combined with --only-pkgs-ext"
	fi
	if ((ONLY_PKGS_EXT && (ONLY_FLAKE || ONLY_EXT || ONLY_IMAGES || ${#ONLY_EXT_NAMES[@]} > 0))); then
		die "--only-pkgs-ext cannot be combined with --only-flake, --only-ext, --only-ext-NAME, or --only-images"
	fi
	if [[ ! "$REPORT_JOBS" =~ ^[1-9][0-9]*$ ]]; then
		die "--jobs must be a positive integer"
	fi
	case "$COLOR_MODE" in
	auto | always | never) ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac

	local name
	for name in "${ONLY_EXT_NAMES[@]}"; do
		contains_name "$name" "${SKIP_EXT_NAMES[@]}" &&
			die "--only-ext-${name} cannot be combined with --skip-ext-${name}"
	done

	((SKIP_FLAKE)) && RUN_FLAKES=0
	((SKIP_EXT)) && RUN_EXT=0
	((SKIP_PKGS_EXT)) && RUN_PKGS_EXT=0
	((SKIP_IMAGES)) && RUN_IMAGES=0
	if ((ONLY_FLAKE)); then
		RUN_FLAKES=1
		RUN_EXT=0
		RUN_PKGS_EXT=0
		RUN_IMAGES=0
	fi
	if ((ONLY_EXT || ${#ONLY_EXT_NAMES[@]} > 0)); then
		RUN_FLAKES=0
		RUN_EXT=1
		RUN_PKGS_EXT=0
		RUN_IMAGES=0
	fi
	if ((ONLY_PKGS_EXT)); then
		RUN_FLAKES=0
		RUN_EXT=0
		RUN_PKGS_EXT=1
		RUN_IMAGES=0
	fi
	if ((ONLY_IMAGES)); then
		RUN_FLAKES=0
		RUN_EXT=0
		RUN_PKGS_EXT=0
		RUN_IMAGES=1
	fi
}

find_flakes() {
	local -a dirs=()
	local f

	while IFS= read -r -d '' f; do
		dirs+=("$(dirname "$f")")
	done < <(
		find "$REPO_ROOT" \
			-path '*/worktrees' -prune -o \
			-path '*/target' -prune -o \
			-name flake.lock -print0
	)
	printf '%s\n' "${dirs[@]}"
}

update_flakes() {
	local dir

	echo "==> Updating root flake: $REPO_ROOT"
	nix flake update --flake "$REPO_ROOT"

	while IFS= read -r dir; do
		[[ "$dir" == "$REPO_ROOT" ]] && continue
		echo "==> Updating child flake: ${dir#"$REPO_ROOT"/}"
		nix flake update --flake "$dir"
	done < <(find_flakes)
}

report_flakes() {
	nix --no-warn-dirty flake metadata --json "$REPO_ROOT" |
		python3 -c '
import json
import sys

metadata = json.load(sys.stdin)
nodes = metadata.get("locks", {}).get("nodes", {})
for name in sorted(k for k in nodes if k != "root"):
    locked = nodes[name].get("locked", {})
    if "rev" in locked:
        version = locked["rev"][:12]
    elif "ref" in locked:
        version = locked["ref"]
    elif "narHash" in locked:
        version = locked["narHash"]
    else:
        version = locked.get("type", "unknown")
    print(f"- {name}: {version}")
'
}

use_color() {
	case "$COLOR_MODE" in
	always) return 0 ;;
	never) return 1 ;;
	auto) [[ -t 1 ]] ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac
}

print_section_title() {
	local title="$1"
	if use_color; then
		printf '\033[1;38;2;255;255;255m%s\033[0m\n' "$title"
	else
		printf '%s\n' "$title"
	fi
}

source_unit_name() {
	local sources_file="$1"
	basename "$(dirname "$sources_file")"
}

should_run_lib_source() {
	local sources_file="$1"
	local name
	name="$(source_unit_name "$sources_file")"

	if ((${#ONLY_EXT_NAMES[@]} > 0)) && ! contains_name "$name" "${ONLY_EXT_NAMES[@]}"; then
		return 1
	fi
	if contains_name "$name" "${SKIP_EXT_NAMES[@]}"; then
		return 1
	fi
	return 0
}

find_source_files() {
	local root="$1"

	find "$root" -mindepth 2 -maxdepth 2 -type f -name sources.nix -print0 | sort -z
}

find_selected_source_files() {
	local root="$1"
	local sources_file

	while IFS= read -r -d '' sources_file; do
		if [[ "$root" != "$LIB_EXT_DIR" ]] || should_run_lib_source "$sources_file"; then
			printf '%s\0' "$sources_file"
		fi
	done < <(find_source_files "$root")
}

validate_source_units() {
	local root="$1"
	local path sibling

	while IFS= read -r -d '' path; do
		sibling="$(dirname "$path")/sources.nix"
		[[ -f "$sibling" ]] || die "External updater has no sibling sources.nix: ${path#"$REPO_ROOT"/}"
	done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name update.sh -print0 | sort -z)

	while IFS= read -r -d '' path; do
		sibling="$(dirname "$path")/update.sh"
		if [[ -f "$sibling" && ! -x "$sibling" ]]; then
			die "External updater is not executable: ${sibling#"$REPO_ROOT"/}"
		fi
	done < <(find_source_files "$root")
}

validate_ext_filters() {
	local sources_file name requested
	local -a ext_names=()

	while IFS= read -r -d '' sources_file; do
		ext_names+=("$(source_unit_name "$sources_file")")
	done < <(find_source_files "$LIB_EXT_DIR")

	for requested in "${ONLY_EXT_NAMES[@]}" "${SKIP_EXT_NAMES[@]}"; do
		contains_name "$requested" "${ext_names[@]}" ||
			die "No lib/ext source unit found for: ${requested}"
	done
}

run_external_updates() {
	local root sources_file update_script
	local -a update_scripts=()

	((RUN_EXT)) && validate_source_units "$LIB_EXT_DIR"
	((RUN_PKGS_EXT)) && validate_source_units "$PKGS_EXT_DIR"
	validate_ext_filters
	for root in "$LIB_EXT_DIR" "$PKGS_EXT_DIR"; do
		if [[ "$root" == "$LIB_EXT_DIR" ]] && ((!RUN_EXT)); then
			continue
		fi
		if [[ "$root" == "$PKGS_EXT_DIR" ]] && ((!RUN_PKGS_EXT)); then
			continue
		fi
		while IFS= read -r -d '' sources_file; do
			update_script="$(dirname "$sources_file")/update.sh"
			[[ -x "$update_script" ]] && update_scripts+=("$update_script")
		done < <(find_selected_source_files "$root")
	done

	if ((${#update_scripts[@]} == 0)); then
		echo "No external update scripts selected."
		return
	fi

	for update_script in "${update_scripts[@]}"; do
		echo "Running ${update_script#"$REPO_ROOT"/}"
		"$update_script"
	done
}

wait_report_job() {
	local pid="$1" label="$2" status
	if wait "$pid"; then
		return 0
	else
		status=$?
		REPORT_FAILURES+=("$label (exit $status)")
		return "$status"
	fi
}

run_source_report() {
	local max_jobs="$1"
	local root="$2"
	local sources_file update_script index
	local -a report_sources=()
	local -a report_commands=()
	local -a pids=()
	local -a labels=()
	local -a report_args=(--report "--color=${COLOR_MODE}")
	local status=0

	validate_source_units "$root"
	validate_ext_filters
	while IFS= read -r -d '' sources_file; do
		update_script="$(dirname "$sources_file")/update.sh"
		if [[ -x "$update_script" ]]; then
			report_commands+=("$update_script")
		else
			report_sources+=("$sources_file")
		fi
	done < <(find_selected_source_files "$root")

	if ((${#report_commands[@]} == 0 && ${#report_sources[@]} == 0)); then
		echo "No external source units selected."
		return
	fi

	for update_script in "${report_commands[@]}"; do
		"$update_script" "${report_args[@]}" &
		pids+=("$!")
		labels+=("${update_script#"$REPO_ROOT"/}")
		while ((${#pids[@]} >= max_jobs)); do
			wait_report_job "${pids[0]}" "${labels[0]}" || status=$?
			pids=("${pids[@]:1}")
			labels=("${labels[@]:1}")
		done
	done
	if ((${#report_sources[@]} > 0)); then
		"${REPO_ROOT}/scripts/support/report-ext-sources.py" \
			--jobs "$max_jobs" "--color=${COLOR_MODE}" "${report_sources[@]}" &
		pids+=("$!")
		labels+=("${root#"$REPO_ROOT"/} source report (scripts/support/report-ext-sources.py)")
	fi

	for index in "${!pids[@]}"; do
		wait_report_job "${pids[index]}" "${labels[index]}" || status=$?
	done
	((status == 0)) || return "$status"
}

run_report() {
	local status=0
	local printed_section=0

	if ((RUN_FLAKES)); then
		print_section_title "flake:"
		report_flakes || {
			status=$?
			REPORT_FAILURES+=("flake metadata (exit $status)")
		}
		printed_section=1
	fi

	if ((RUN_EXT)); then
		((printed_section)) && echo
		print_section_title "lib/ext:"
		run_source_report "$REPORT_JOBS" "$LIB_EXT_DIR" || status=$?
		printed_section=1
	fi

	if ((RUN_PKGS_EXT)); then
		((printed_section)) && echo
		print_section_title "pkgs/ext:"
		run_source_report "$REPORT_JOBS" "$PKGS_EXT_DIR" || status=$?
		printed_section=1
	fi

	if ((RUN_IMAGES)); then
		((printed_section)) && echo
		print_section_title "podman-compose images:"
		"${REPO_ROOT}/scripts/support/podman-image-updater.py" \
			--report --jobs "$REPORT_JOBS" "--color=${COLOR_MODE}" || {
			status=$?
			REPORT_FAILURES+=("scripts/support/podman-image-updater.py (exit $status)")
		}
	fi

	if ((status != 0)); then
		printf '\nReport failures:\n' >&2
		printf -- '- %s\n' "${REPORT_FAILURES[@]}" >&2
		return "$status"
	fi
}

run_updates() {
	if ((REPORT)); then
		run_report
		return
	fi

	if ((RUN_FLAKES)); then
		update_flakes
	fi
	if ((RUN_EXT || RUN_PKGS_EXT)); then
		run_external_updates
	fi
	if ((RUN_IMAGES)); then
		echo "Updating podman-compose images:"
		"${REPO_ROOT}/scripts/support/podman-image-updater.py" \
			--jobs "$REPORT_JOBS" "--color=${COLOR_MODE}"
	fi
}

main() {
	init_vars
	parse_args "$@"
	normalize_options
	run_updates
}

main "$@"

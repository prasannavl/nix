#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: update.sh [options]

Runs all repo maintenance update scripts:
  flake lock updates
  lib/ext/*/update.sh

Options:
  --skip-flake          Do not update flake locks.
  --only-flake          Only update flake locks.
  --skip-ext            Do not run extension update scripts.
  --only-ext            Only run extension update scripts.
  --skip-ext-NAME       Skip lib/ext/NAME/update.sh.
  --only-ext-NAME       Only run lib/ext/NAME/update.sh. May be repeated.
  --skip-pkgs-ext       Do not include patched pkgs/ext reports.
  --only-pkgs-ext       Only include patched pkgs/ext reports.
  --skip-images         Do not include Podman image reports.
  --only-images         Only include Podman image reports.
  --jobs N              Parallel report jobs. Default: 16.
  --ansi                Always use ANSI styling for report updates.
  --color[=WHEN]        Report styling: auto, always, never. Default: auto.
  --report              Print package version status without updating.
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	EXT_DIR="${REPO_ROOT}/lib/ext"
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

ext_name_for_script() {
	local script="$1"
	basename "$(dirname "$script")"
}

should_run_ext_script() {
	local script="$1"
	local name
	name="$(ext_name_for_script "$script")"

	if ((${#ONLY_EXT_NAMES[@]} > 0)) && ! contains_name "$name" "${ONLY_EXT_NAMES[@]}"; then
		return 1
	fi
	if contains_name "$name" "${SKIP_EXT_NAMES[@]}"; then
		return 1
	fi
	return 0
}

find_selected_ext_scripts() {
	local script

	while IFS= read -r -d '' script; do
		should_run_ext_script "$script" && printf '%s\0' "$script"
	done < <(find "$EXT_DIR" -mindepth 2 -maxdepth 2 -type f -name update.sh -executable -print0 | sort -z)
}

validate_ext_filters() {
	local script name requested
	local -a ext_names=()

	while IFS= read -r -d '' script; do
		ext_names+=("$(ext_name_for_script "$script")")
	done < <(find "$EXT_DIR" -mindepth 2 -maxdepth 2 -type f -name update.sh -executable -print0 | sort -z)

	for requested in "${ONLY_EXT_NAMES[@]}" "${SKIP_EXT_NAMES[@]}"; do
		contains_name "$requested" "${ext_names[@]}" ||
			die "No extension update script found for: ${requested}"
	done
}

run_ext_updates() {
	local script
	local -a update_scripts=()

	validate_ext_filters
	while IFS= read -r -d '' script; do
		update_scripts+=("$script")
	done < <(find_selected_ext_scripts)

	if ((${#update_scripts[@]} == 0)); then
		echo "No extension update scripts selected."
		return
	fi

	for script in "${update_scripts[@]}"; do
		echo "Running ${script#"$REPO_ROOT"/}"
		"$script"
	done
}

run_ext_report() {
	local script
	local -a update_scripts=()
	local -a pids=()
	local -a report_args=(--report "--color=${COLOR_MODE}")
	local max_jobs="$1"
	local pid
	local status=0

	validate_ext_filters
	while IFS= read -r -d '' script; do
		update_scripts+=("$script")
	done < <(find_selected_ext_scripts)

	if ((${#update_scripts[@]} == 0)); then
		echo "No package update scripts selected."
		return
	fi

	for script in "${update_scripts[@]}"; do
		"$script" "${report_args[@]}" &
		pids+=("$!")
		while ((${#pids[@]} >= max_jobs)); do
			wait "${pids[0]}" || status=$?
			pids=("${pids[@]:1}")
		done
	done

	for pid in "${pids[@]}"; do
		wait "$pid" || status=$?
	done
	((status == 0)) || return "$status"
}

run_report() {
	local status=0
	local printed_section=0

	if ((RUN_FLAKES)); then
		print_section_title "flake:"
		report_flakes
		printed_section=1
	fi

	if ((RUN_EXT)); then
		((printed_section)) && echo
		print_section_title "lib/ext:"
		run_ext_report "$REPORT_JOBS" || status=$?
		printed_section=1
	fi

	if ((RUN_PKGS_EXT)); then
		((printed_section)) && echo
		print_section_title "pkgs/ext:"
		"${REPO_ROOT}/scripts/support/report-pkgs-ext.py" --jobs "$REPORT_JOBS" "--color=${COLOR_MODE}" || status=$?
		printed_section=1
	fi

	if ((RUN_IMAGES)); then
		((printed_section)) && echo
		print_section_title "podman-compose images:"
		"${REPO_ROOT}/scripts/support/report-podman-images.py" --jobs "$REPORT_JOBS" "--color=${COLOR_MODE}" || status=$?
	fi

	((status == 0)) || return "$status"
}

run_updates() {
	if ((REPORT)); then
		run_report
		return
	fi

	if ((RUN_FLAKES)); then
		update_flakes
	fi
	if ((RUN_EXT)); then
		run_ext_updates
	fi
}

main() {
	init_vars
	parse_args "$@"
	normalize_options
	run_updates
}

main "$@"

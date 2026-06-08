#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/clean.sh [options]

Modes:
  (default)     Recursive cleanup.
  -R, --no-recurse
                Clear only root cargo target and root Nix result outputs.
  -C, --child-only
                Clear child cargo target dirs and child Nix result symlinks only.
  -r, --recurse
                Also clear child cargo target dirs and child Nix result symlinks.

Cleanup:
  - Remove every flake.lock except the root flake.lock.
  - Remove cargo target dirs.
  - Remove Nix result/result-* symlinks into /nix/store.
  - Remove root result-dev symlinks into /nix/store, then remove it if empty.
  - Run scripts/age-secrets.sh -c.
  - Remove tmp/* except tmp/data.

Options:
  -kt, --keep-target, --keep-cargo-target
  -kf, --keep-flake-lock
  -kr, --keep-result
  -a, -ka, --keep-age-secrets
  -kT, --keep-tmp
  -n, --dry-run
  -h, --help

Notes:
  - .git and worktrees/ are never traversed.
  - result/result-* paths are removed only when they are symlinks to /nix/store.
EOF
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
	CLEAN_RECURSE=1
	CLEAN_CHILD_ONLY=0
	KEEP_TARGET=0
	KEEP_FLAKE_LOCK=0
	KEEP_RESULT=0
	KEEP_AGE_SECRETS=0
	KEEP_TMP=0
	DRY_RUN=0
}

log_action() {
	printf '%s\n' "$*"
}

run_rm() {
	local path="$1"

	if [ "$DRY_RUN" = 1 ]; then
		log_action "- ${path#"$REPO_ROOT"/}"
		return 0
	fi

	log_action "remove: ${path#"$REPO_ROOT"/}"
	rm -rf -- "$path"
}

is_nix_store_symlink() {
	local path="$1"
	local target

	[ -L "$path" ] || return 1
	target="$(readlink -f -- "$path" 2>/dev/null || true)"
	[[ "$target" == /nix/store/* ]]
}

find_repo_paths() {
	find "$REPO_ROOT" \
		-path "${REPO_ROOT}/.git" -prune -o \
		-path "${REPO_ROOT}/worktrees" -prune -o \
		"$@"
}

remove_flake_locks() {
	local path

	[ "$KEEP_FLAKE_LOCK" = 0 ] || return 0

	while IFS= read -r -d '' path; do
		[ "$path" != "${REPO_ROOT}/flake.lock" ] || continue
		run_rm "$path"
	done < <(find_repo_paths -name flake.lock -type f -print0)
}

remove_root_target() {
	local path="${REPO_ROOT}/target"

	[ "$KEEP_TARGET" = 0 ] || return 0
	[ -d "$path" ] || return 0
	run_rm "$path"
}

remove_recursive_targets() {
	local path

	[ "$KEEP_TARGET" = 0 ] || return 0

	while IFS= read -r -d '' path; do
		[ "$CLEAN_CHILD_ONLY" = 0 ] || [ "$path" != "${REPO_ROOT}/target" ] || continue
		run_rm "$path"
	done < <(find_repo_paths -name target -type d -print0 -prune)
}

remove_result_symlink() {
	local path="$1"

	is_nix_store_symlink "$path" || return 0
	run_rm "$path"
}

remove_root_results() {
	local path

	[ "$KEEP_RESULT" = 0 ] || return 0

	for path in "${REPO_ROOT}/result" "${REPO_ROOT}"/result-*; do
		[ -e "$path" ] || [ -L "$path" ] || continue
		remove_result_symlink "$path"
	done
}

remove_recursive_results() {
	local path

	[ "$KEEP_RESULT" = 0 ] || return 0

	while IFS= read -r -d '' path; do
		if [ "$CLEAN_CHILD_ONLY" = 1 ]; then
			case "$path" in
			"${REPO_ROOT}/result" | "${REPO_ROOT}"/result-*) continue ;;
			esac
		fi
		remove_result_symlink "$path"
	done < <(find_repo_paths \( -name result -o -name 'result-*' \) -print0)
}

clean_root_result_dev() {
	local dir="${REPO_ROOT}/result-dev"
	local path

	[ "$KEEP_RESULT" = 0 ] || return 0
	[ -d "$dir" ] || return 0

	while IFS= read -r -d '' path; do
		remove_result_symlink "$path"
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)

	if [ "$DRY_RUN" = 1 ]; then
		find "$dir" -mindepth 1 -maxdepth 1 -quit | grep -q . || log_action "- result-dev"
		return 0
	fi

	rmdir "$dir" 2>/dev/null && log_action "remove: result-dev" || true
}

clean_age_secrets() {
	[ "$KEEP_AGE_SECRETS" = 0 ] || return 0

	if [ "$DRY_RUN" = 1 ]; then
		"${REPO_ROOT}/scripts/age-secrets.sh" --dry-run -c
		return 0
	fi
	log_action "run: scripts/age-secrets.sh -c"
	"${REPO_ROOT}/scripts/age-secrets.sh" -c
}

clean_tmp() {
	local dir="${REPO_ROOT}/tmp"
	local path

	[ "$KEEP_TMP" = 0 ] || return 0
	[ -d "$dir" ] || return 0

	while IFS= read -r -d '' path; do
		[ "$(basename "$path")" != data ] || continue
		run_rm "$path"
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-R | --no-recurse)
			CLEAN_RECURSE=0
			CLEAN_CHILD_ONLY=0
			;;
		-C | --child-only)
			CLEAN_RECURSE=1
			CLEAN_CHILD_ONLY=1
			;;
		-r | --recurse)
			CLEAN_RECURSE=1
			CLEAN_CHILD_ONLY=0
			;;
		-kt | --keep-target | --keep-cargo-target)
			KEEP_TARGET=1
			;;
		-kf | --keep-flake-lock | --keep-flakelock)
			KEEP_FLAKE_LOCK=1
			;;
		-kr | --keep-result | --keep-results)
			KEEP_RESULT=1
			;;
		-a | -ka | --keep-age-secrets | --keep-secrets)
			KEEP_AGE_SECRETS=1
			;;
		-kT | --keep-tmp)
			KEEP_TMP=1
			;;
		-n | --dry-run)
			DRY_RUN=1
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			die "unknown argument: $1"
			;;
		esac
		shift
	done
}

main() {
	init_vars
	parse_args "$@"

	cd "$REPO_ROOT"
	remove_flake_locks
	if [ "$CLEAN_RECURSE" = 1 ]; then
		remove_recursive_targets
		remove_recursive_results
	else
		remove_root_target
		remove_root_results
	fi
	if [ "$CLEAN_CHILD_ONLY" = 0 ]; then
		clean_root_result_dev
	fi
	clean_age_secrets
	clean_tmp
}

main "$@"

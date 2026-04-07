#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/age-secrets.sh [-v] encrypt [path]
  scripts/age-secrets.sh [-v] decrypt [path]
  scripts/age-secrets.sh [-v] clean [path]
  scripts/age-secrets.sh [-v] -e [path]
  scripts/age-secrets.sh [-v] -d [path]
  scripts/age-secrets.sh [-v] -c [path]
  scripts/age-secrets.sh [-v] [path]
Behavior:
  encrypt   Encrypts managed plaintext files to managed *.age files.
  decrypt   Decrypts managed *.age files to plaintext alongside them (drops .age suffix).
  clean     Deletes managed plaintext files that correspond to managed *.age files.
  (no mode) Auto-toggle: encrypt if any managed plaintext exists, otherwise decrypt.
Notes:
  - Default scope is all files listed in data/secrets/default.nix.
  - Pass [path] to limit the run to one managed subtree or one managed file.
  - Only files listed in data/secrets/default.nix are managed.
  - encrypt does not delete plaintext source files.
  - decrypt uses AGE_KEY_FILE, or defaults to ~/.ssh/id_ed25519.
  - decrypt continues across other files even if one file fails to decrypt.
  - use -v / --verbose to print per-file decrypt failures and other detailed logs.
  - clean only deletes plaintext siblings of managed *.age files.
EOF
}

die() {
	echo "Error: $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH"
}

init_vars() {
	REPO_ROOT="$(repo_root)"
	MANAGED_SECRETS_FILE="${REPO_ROOT}/data/secrets/default.nix"
	AGE_DECRYPT_IDENTITY_FILE="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
	VERBOSE="${VERBOSE:-0}"
}

repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || pwd
}

rel_from_root() {
	local root="$1"
	local path="$2"
	realpath --relative-to="$root" "$path"
}

load_recipients_json() {
	nix eval --json --file "${MANAGED_SECRETS_FILE}"
}

resolve_target_path() {
	local target_path="${1:-}"

	if [ -z "$target_path" ]; then
		echo ""
		return 0
	fi

	target_path="${REPO_ROOT}/${target_path}"
	[ -e "$target_path" ] || die "Path not found: $target_path"
	echo "$target_path"
}

load_managed_files() {
	local root="$1"
	local target_path="${2:-}"
	local recipients_json="$3"
	local target_rel
	local age_rel

	if [ -z "$target_path" ]; then
		jq -r 'keys[]' <<<"$recipients_json"
		return 0
	fi

	target_rel="$(realpath --relative-to "$root" "$target_path")"

	if [ -d "$target_path" ]; then
		jq -r --arg pfx "${target_rel}/" 'keys[] | select(startswith($pfx))' <<<"$recipients_json"
		return 0
	fi

	if jq -e --arg p "$target_rel" 'has($p)' <<<"$recipients_json" >/dev/null; then
		printf '%s\n' "$target_rel"
		return 0
	fi

	age_rel="${target_rel}.age"
	if jq -e --arg p "$age_rel" 'has($p)' <<<"$recipients_json" >/dev/null; then
		printf '%s\n' "$age_rel"
	fi
}

encrypt_file() {
	local root="$1"
	local recipients_json="$2"
	local plaintext="$3"
	local output rel_out
	local -a recipients=()
	local -a args=()

	output="${plaintext}.age"
	rel_out="$(rel_from_root "$root" "$output")"

	mapfile -t recipients < <(jq -r --arg p "$rel_out" '.[$p].publicKeys[]? // empty' <<<"$recipients_json")
	if [ "${#recipients[@]}" -eq 0 ]; then
		die "No recipients configured for ${rel_out} in $(rel_from_root "$REPO_ROOT" "$MANAGED_SECRETS_FILE")"
	fi

	for recipient in "${recipients[@]}"; do
		args+=(-r "$recipient")
	done

	echo "encrypt: ${plaintext} -> ${output}"
	age "${args[@]}" -o "$output" "$plaintext"
}

decrypt_file() {
	local encrypted="$1"
	local output
	local tmp_output
	local age_err=""

	output="${encrypted%.age}"
	tmp_output="$(mktemp "${output}.tmp.XXXXXX")"
	trap 'rm -f -- "${tmp_output:-}"' RETURN

	: >"$tmp_output"
	if age_err="$(age --decrypt -i "$AGE_DECRYPT_IDENTITY_FILE" -o "$tmp_output" "$encrypted" 2>&1)"; then
		mv "$tmp_output" "$output"
		echo "decrypt: ${encrypted} -> ${output}"
		trap - RETURN
		return 0
	fi
	rm -f -- "$tmp_output"
	if [ "$VERBOSE" = "1" ]; then
		echo "decrypt failed: ${encrypted}" >&2
		[ -n "$age_err" ] && printf '%s\n' "$age_err" >&2
	fi
	trap - RETURN
	return 1
}

parse_args() {
	local mode_name="$1"
	local target_dir_name="$2"
	local verbose_name="$3"
	shift 3
	local raw_mode
	local raw_target_dir="${2:-}"
	local parsed_mode=""
	local parsed_target_dir=""
	local parsed_verbose="0"
	local arg
	local -a positionals=()

	for arg in "$@"; do
		case "$arg" in
		-v | --verbose) parsed_verbose="1" ;;
		*) positionals+=("$arg") ;;
		esac
	done

	raw_mode="${positionals[0]:-}"
	raw_target_dir="${positionals[1]:-}"
	parsed_mode="$raw_mode"
	parsed_target_dir="$raw_target_dir"

	if [ -n "$raw_mode" ] && [[ "$raw_mode" != -* ]]; then
		case "$raw_mode" in
		encrypt | decrypt | clean | -e | -d | -c) ;;
		*)
			parsed_mode=""
			parsed_target_dir="$raw_mode"
			raw_mode=""
			;;
		esac
	fi

	case "$raw_mode" in
	encrypt | decrypt | clean) ;;
	-e) parsed_mode="encrypt" ;;
	-d) parsed_mode="decrypt" ;;
	-c) parsed_mode="clean" ;;
	-h | --help)
		usage
		exit 0
		;;
	"")
		if [ -n "${1:-}" ] && [[ "${1}" != -* ]]; then
			parsed_target_dir="${1}"
		fi
		;;
	*)
		usage
		die "Unknown mode: $raw_mode"
		;;
	esac

	printf -v "$mode_name" '%s' "$parsed_mode"
	printf -v "$target_dir_name" '%s' "$parsed_target_dir"
	printf -v "$verbose_name" '%s' "$parsed_verbose"
}

ensure_decrypt_identity_file() {
	[ -f "$AGE_DECRYPT_IDENTITY_FILE" ] || die "Decrypt identity file not found: $AGE_DECRYPT_IDENTITY_FILE"
}

collect_candidates() {
	local root="$1"
	local managed_name="$2"
	local enc_name="$3"
	local dec_name="$4"
	local clean_name="$5"
	local plaintext_count_name="$6"
	local -n managed_ref="$managed_name"
	local -n enc_ref="$enc_name"
	local -n dec_ref="$dec_name"
	local -n clean_ref="$clean_name"
	local -n plaintext_count_ref="$plaintext_count_name"
	local rel abs plain enc

	for rel in "${managed_ref[@]}"; do
		abs="$root/$rel"
		if [[ "$abs" != *.age ]]; then
			continue
		fi

		enc="$abs"
		plain="${abs%.age}"
		dec_ref+=("$enc")
		enc_ref+=("$plain")
		clean_ref+=("$plain")
		if [ -f "$plain" ]; then
			plaintext_count_ref=$((plaintext_count_ref + 1))
		fi
	done
}

filter_existing_files() {
	local out_name="$1"
	shift
	local -n out_ref="$out_name"
	local path

	out_ref=()
	for path in "$@"; do
		if [ -f "$path" ]; then
			out_ref+=("$path")
		fi
	done
}

report_no_managed_files() {
	local target_path="${1:-}"
	local managed_secrets_label

	managed_secrets_label="$(rel_from_root "$REPO_ROOT" "$MANAGED_SECRETS_FILE")"

	if [ -n "$target_path" ]; then
		echo "No managed secrets found for $target_path (from ${managed_secrets_label})"
	else
		echo "No managed secrets found in ${managed_secrets_label}"
	fi
}

report_no_mode_files() {
	local mode="$1"
	local target_path="${2:-}"
	local message

	case "$mode" in
	encrypt) message="No managed plaintext .key files found" ;;
	decrypt) message="No managed .age files found" ;;
	clean) message="No managed decrypted plaintext files found" ;;
	*) die "Unsupported mode for empty-state message: $mode" ;;
	esac

	if [ -n "$target_path" ]; then
		echo "${message} for $target_path"
	else
		echo "$message"
	fi
}

resolve_mode() {
	local mode="${1:-}"
	local plaintext_count="$2"

	if [ -n "$mode" ]; then
		echo "$mode"
		return 0
	fi

	if [ "$plaintext_count" -gt 0 ]; then
		echo "encrypt"
	else
		echo "decrypt"
	fi
}

run_mode() {
	local mode="$1"
	local target_path="$2"
	local root="$3"
	local recipients_json="$4"
	shift 4
	local -a files=("$@")
	local f
	local -a failed_files=()
	local success_count=0

	if [ "${#files[@]}" -eq 0 ]; then
		report_no_mode_files "$mode" "$target_path"
		return 0
	fi

	case "$mode" in
	encrypt)
		for f in "${files[@]}"; do
			encrypt_file "$root" "$recipients_json" "$f"
		done
		;;
	decrypt)
		ensure_decrypt_identity_file
		echo "decrypt identity: ${AGE_DECRYPT_IDENTITY_FILE}"
		for f in "${files[@]}"; do
			if ! decrypt_file "$f"; then
				failed_files+=("$f")
			else
				success_count=$((success_count + 1))
			fi
		done
		if [ "${#failed_files[@]}" -gt 0 ]; then
			echo "decrypt: ${success_count}/${#files[@]} succeeded; use -v/--verbose for details" >&2
			return 1
		fi
		echo "decrypt: ${success_count}/${#files[@]} succeeded"
		;;
	clean)
		for f in "${files[@]}"; do
			echo "clean: removing ${f}"
			rm -f -- "$f"
		done
		;;
	*)
		die "Unsupported mode: $mode"
		;;
	esac
}

ensure_runtime_shell() {
	local runtime_shell_flag="${AGE_SECRETS_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#age
		nixpkgs#coreutils
		nixpkgs#git
		nixpkgs#jq
	)

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "'nix' is required but not found in PATH"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env AGE_SECRETS_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	local mode=""
	local target_path=""
	local requested_mode=""
	local verbose="0"
	local recipients_json
	local -a files=()
	local -a managed=()
	local -a enc_candidates=()
	local -a dec_candidates=()
	local -a clean_candidates=()
	local plaintext_count=0

	ensure_runtime_shell "$@"
	init_vars
	parse_args mode target_path verbose "$@"
	requested_mode="$mode"

	require_cmd age
	require_cmd jq
	require_cmd mktemp
	require_cmd nix
	require_cmd realpath
	VERBOSE="$verbose"
	target_path="$(resolve_target_path "$target_path")"

	recipients_json="$(load_recipients_json)"
	mapfile -t managed < <(load_managed_files "$REPO_ROOT" "$target_path" "$recipients_json")

	if [ "${#managed[@]}" -eq 0 ]; then
		report_no_managed_files "$target_path"
		exit 0
	fi

	collect_candidates \
		"$REPO_ROOT" \
		managed \
		enc_candidates \
		dec_candidates \
		clean_candidates \
		plaintext_count

	mode="$(resolve_mode "$mode" "$plaintext_count")"
	if [ -z "$requested_mode" ]; then
		echo "mode: ${mode} (auto)"
	fi

	case "$mode" in
	encrypt) filter_existing_files files "${enc_candidates[@]}" ;;
	decrypt) filter_existing_files files "${dec_candidates[@]}" ;;
	clean) filter_existing_files files "${clean_candidates[@]}" ;;
	*) die "Unsupported mode: $mode" ;;
	esac

	run_mode "$mode" "$target_path" "$REPO_ROOT" "$recipients_json" "${files[@]}"
}

main "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/age-secrets.sh encrypt [dir]
  scripts/age-secrets.sh decrypt [dir]
  scripts/age-secrets.sh -e [dir]
  scripts/age-secrets.sh -d [dir]
  scripts/age-secrets.sh [dir]

Behavior:
  encrypt   Encrypts managed *.key files to *.key.age.
  decrypt   Decrypts managed *.age files to plaintext alongside them (drops .age suffix).
  (no mode) Auto-toggle: encrypt if any managed plaintext exists, otherwise decrypt.

Notes:
  - Default dir is data/secrets.
  - Only files listed in data/secrets/default.nix are managed.
  - encrypt does not delete plaintext source files.
  - decrypt uses AGE_KEY_FILE, or defaults to ~/.ssh/id_ed25519.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH"
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
  local root="$1"
  nix eval --json --file "$root/data/secrets/default.nix"
}

load_managed_files() {
  local root="$1"
  local target_dir="$2"
  local recipients_json="$3"
  local target_rel

  target_rel="$(realpath --relative-to "$root" "$target_dir")"
  jq -r --arg pfx "${target_rel}/" 'keys[] | select(startswith($pfx))' <<<"$recipients_json"
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
    die "No recipients configured for ${rel_out} in data/secrets/default.nix"
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
  local age_key_file="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"

  output="${encrypted%.age}"
  echo "decrypt: ${encrypted} -> ${output}"
  echo "decrypt identity: ${age_key_file}"
  [ -f "$age_key_file" ] || die "Decrypt identity file not found: $age_key_file"
  age --decrypt -i "$age_key_file" -o "$output" "$encrypted"
}

main() {
  local mode="${1:-}"
  local target_dir="${2:-}"
  local root recipients_json
  local -a files=()
  local -a managed=()
  local -a enc_candidates=()
  local -a dec_candidates=()
  local rel abs plain enc
  local plaintext_count=0

  case "$mode" in
    encrypt|decrypt|-e|-d) ;;
    -h|--help)
      usage
      exit 0
      ;;
    "")
      if [ -n "${1:-}" ] && [[ ! "${1}" =~ ^- ]]; then
        target_dir="${1}"
      fi
      ;;
    *)
      usage
      die "Unknown mode: $mode"
      ;;
  esac

  if [ -z "${target_dir}" ]; then
    target_dir="data/secrets"
  fi

  case "$mode" in
    -e) mode="encrypt" ;;
    -d) mode="decrypt" ;;
  esac

  require_cmd age
  require_cmd jq
  require_cmd nix
  require_cmd realpath

  root="$(repo_root)"
  target_dir="$root/$target_dir"
  [ -d "$target_dir" ] || die "Directory not found: $target_dir"

  recipients_json="$(load_recipients_json "$root")"
  mapfile -t managed < <(load_managed_files "$root" "$target_dir" "$recipients_json")

  if [ "${#managed[@]}" -eq 0 ]; then
    echo "No managed secrets found under $target_dir (from data/secrets/default.nix)"
    exit 0
  fi

  for rel in "${managed[@]}"; do
    abs="$root/$rel"
    if [[ "$abs" = *.age ]]; then
      enc="$abs"
      plain="${abs%.age}"
      dec_candidates+=("$enc")
      enc_candidates+=("$plain")
      if [ -f "$plain" ]; then
        plaintext_count=$((plaintext_count + 1))
      fi
    fi
  done

  if [ -z "$mode" ]; then
    if [ "$plaintext_count" -gt 0 ]; then
      mode="encrypt"
    else
      mode="decrypt"
    fi
    echo "mode: ${mode} (auto)"
  fi

  if [ "$mode" = "encrypt" ]; then
    files=()
    for f in "${enc_candidates[@]}"; do
      [ -f "$f" ] && files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
      echo "No managed plaintext .key files found under $target_dir"
      exit 0
    fi
    for f in "${files[@]}"; do
      encrypt_file "$root" "$recipients_json" "$f"
    done
    exit 0
  fi

  files=()
  for f in "${dec_candidates[@]}"; do
    [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    echo "No managed .age files found under $target_dir"
    exit 0
  fi
  for f in "${files[@]}"; do
    decrypt_file "$f"
  done
}

main "$@"

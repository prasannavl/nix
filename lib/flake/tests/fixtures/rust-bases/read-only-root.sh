# Appended to the helper-generated projection functions in rust-bases.nix.
# Keep the failing cp diagnostics and successful outputs in owned scratch.
check_projection() {
  local name="$1" scratch="$2" expected="$3" out inode_before
  out="$scratch/$name"
  mkdir -p "$out"

  # Match Crane's order: copy cleaned source, chmod recursively, THEN copy
  # generated TOML as a NEW file. The earlier chmod cannot make it writable.
  cp --recursive --no-preserve=ownership "$scratch/cleaned/." -t "$out"
  chmod +w -R "$out"
  cp "$scratch/generated.toml" "$out/Cargo.toml"
  mkdir -p "$out/member"
  cp "$scratch/generated.toml" "$out/member/Cargo.toml"
  [[ "$(stat -c %a "$out/Cargo.toml")" == 444 ]]
  inode_before="$(stat -c %i "$out/Cargo.toml")"

  # This is the old extraDummyScript. Failure must be ordinary EACCES, not
  # an absent file/tool or a root run that silently bypasses the permissions.
  if LC_ALL=C cp "$expected" "$out/Cargo.toml" 2> "$scratch/$name-before.stderr"; then
    printf '%s: old projection unexpectedly overwrote mode 0444\n' "$name" >&2
    return 1
  fi
  grep -q 'Permission denied' "$scratch/$name-before.stderr"
  cmp "$scratch/generated.toml" "$out/Cargo.toml"
  printf '%s: before failed on readonly Cargo.toml (expected)\n' "$name"

  # Invoke the ACTUAL helper-produced extra script from fake Crane's
  # src.buildCommand, not a duplicated chmod/cp implementation in the test.
  "${name}_projection"
  cmp "$expected" "$out/Cargo.toml"
  [[ "$(stat -c %a "$out/Cargo.toml")" == 644 ]]
  [[ "$(stat -c %i "$out/Cargo.toml")" == "$inode_before" ]]
  [[ "$(stat -c %a "$out/member/Cargo.toml")" == 444 ]]
  cmp "$scratch/generated.toml" "$out/member/Cargo.toml"
  [[ "$(stat -c %a "$scratch/generated.toml")" == 444 ]]
  printf '%s: after succeeded; projected bytes, inode and member mode verified\n' "$name"
}

main() {
  local temp_root="${1:?pass an existing user-owned scratch directory}" expected="${2:?}" scratch
  [[ "$EUID" != 0 ]]
  [[ -d "$temp_root" && -O "$temp_root" ]]
  scratch="$(mktemp -d "$temp_root/root-projection.XXXXXX")"
  mkdir -p "$scratch/cleaned"
  printf 'cleaned-source sentinel\n' > "$scratch/cleaned/sentinel"
  printf '[workspace]\nresolver = "2"\nmembers = ["unprojected"]\n' > "$scratch/generated.toml"
  chmod 444 "$scratch/generated.toml" "$scratch/cleaned/sentinel"
  check_projection unchained "$scratch" "$expected"
  check_projection chained "$scratch" "$expected"
  printf 'source-script regression passed as uid=%s; evidence=%s\n' "$EUID" "$scratch"
}

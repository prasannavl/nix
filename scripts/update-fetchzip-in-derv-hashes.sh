#!/usr/bin/env bash
set -Eeuo pipefail

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	TARGET_DIR="${REPO_ROOT}/pkgs/ext"
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_FETCHZIP_HASHES_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#coreutils
		nixpkgs#findutils
		nixpkgs#gnused
		nixpkgs#jq
	)
	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi
	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi
	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_FETCHZIP_HASHES_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	local file
	local url
	local hash
	local eval_result
	local -a target_files=()

	ensure_runtime_shell "$@"
	init_vars

	if [[ -d "$TARGET_DIR" ]]; then
		while IFS= read -r -d '' file; do
			target_files+=("$file")
		done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name '*.nix' -print0)
	fi

	if [[ "${#target_files[@]}" -eq 0 ]]; then
		echo "No fetchzip package files found under ${TARGET_DIR#"$REPO_ROOT"/}"
		return
	fi

	for file in "${target_files[@]}"; do
		eval_result="$(FILE_PATH="$file" nix eval --raw --impure --expr '
      let
        f = import (builtins.toPath (builtins.getEnv "FILE_PATH"));
        functionArgs = builtins.functionArgs f;
      in
        if !(builtins.hasAttr "fetchzip" functionArgs) then
          "__SKIP__"
        else
          let
            args = builtins.mapAttrs (name: _:
              if name == "stdenv" then { mkDerivation = x: x; }
              else if name == "fetchzip" then (x: x)
              else {}
            ) functionArgs;
            pkg = f args;
          in
            if pkg ? src && pkg.src ? url then pkg.src.url else "__SKIP__"
    ')"
		if [ "$eval_result" = "__SKIP__" ]; then
			continue
		fi
		url="$eval_result"
		hash="$(nix store prefetch-file --json --hash-type sha256 --unpack "$url" | jq -r .hash)"
		sed -E -i "s#(sha256 = \").*(\";)#\1$hash\2#" "$file"
		echo "$(basename "$file"): $hash"
	done
}

main "$@"

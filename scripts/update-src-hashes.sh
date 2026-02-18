#!/usr/bin/env bash
set -euo pipefail

for file in "$(dirname "$0")"/../pkgs/*.nix; do
  abs_file=$(realpath "$file")
  url=$(FILE_PATH="$abs_file" nix eval --raw --impure --expr '
    let
      f = import (builtins.toPath (builtins.getEnv "FILE_PATH"));
      args = builtins.mapAttrs (name: _:
        if name == "stdenv" then { mkDerivation = x: x; }
        else if name == "fetchzip" then (x: x)
        else null
      ) (builtins.functionArgs f);
      pkg = f args;
    in pkg.src.url
  ')

  hash=$(nix store prefetch-file --json --hash-type sha256 --unpack "$url" | jq -r .hash)
  sed -E -i "s#(sha256 = \").*(\";)#\1$hash\2#" "$abs_file"
  echo "$(basename "$abs_file"): $hash"
done

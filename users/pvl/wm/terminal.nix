{pkgs}: let
  package = pkgs.writeShellScriptBin "wm-terminal" ''
    for terminal in alacritty foot; do
      if command -v "$terminal" >/dev/null 2>&1; then
        exec "$terminal" "$@"
      fi
    done

    echo "no terminal found: alacritty, foot" >&2
    exit 127
  '';
in {
  package = package;
  bin = "${package}/bin/wm-terminal";
}

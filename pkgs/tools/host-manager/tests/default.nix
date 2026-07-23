{pkgs}: {
  helper =
    pkgs.runCommand "host-manager-helper-test" {
      NIX_CONFIG = "experimental-features = nix-command flakes";
      nativeBuildInputs = [
        pkgs.alejandra
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.nix
        pkgs.openssh
        pkgs.python3
      ];
    } ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      repo="$TMPDIR/repo"
      mkdir -p "$repo/pkgs/tools"
      cp -R ${../.} "$repo/pkgs/tools/host-manager"
      mkdir -p "$repo/pkgs"
      cp ${../../../manifest.nix} "$repo/pkgs/manifest.nix"
      cp ${../../../../flake.nix} "$repo/flake.nix"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/pkgs/tools/host-manager/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}

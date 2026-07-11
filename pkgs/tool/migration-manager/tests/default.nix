{pkgs}: {
  helper =
    pkgs.runCommand "migration-manager-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/pkgs/tool"
      cp -R ${../.} "$repo/pkgs/tool/migration-manager"
      mkdir -p "$repo/pkgs"
      cp ${../../../manifest.nix} "$repo/pkgs/manifest.nix"
      cp ${../../../../flake.nix} "$repo/flake.nix"
      chmod -R u+w "$repo"
      bash "$repo/pkgs/tool/migration-manager/tests/test_helper.sh"
      python -m unittest discover \
        --start-directory "$repo/pkgs/tool/migration-manager/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}

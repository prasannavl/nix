{pkgs}: {
  helper =
    pkgs.runCommand "migrator-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/pkgs/tools"
      cp -R ${../.} "$repo/pkgs/tools/migrator"
      mkdir -p "$repo/pkgs"
      cp ${../../../manifest.nix} "$repo/pkgs/manifest.nix"
      cp ${../../../../flake.nix} "$repo/flake.nix"
      chmod -R u+w "$repo"
      bash "$repo/pkgs/tools/migrator/tests/test_migrator_helper.sh"
      python -m unittest discover \
        --start-directory "$repo/pkgs/tools/migrator/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}

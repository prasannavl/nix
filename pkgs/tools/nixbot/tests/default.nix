{pkgs}: {
  helper =
    pkgs.runCommand "nixbot-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gawk
        pkgs.git
        pkgs.gnused
        pkgs.jq
        pkgs.python3
        pkgs.procps
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/pkgs/tools"
      cp -R ${../.} "$repo/pkgs/tools/nixbot"
      cp -R ${../../../../.agents} "$repo/.agents"
      cp ${../../../../flake.nix} "$repo/flake.nix"
      mkdir -p "$repo/pkgs"
      cp ${../../../manifest.nix} "$repo/pkgs/manifest.nix"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/pkgs/tools/nixbot/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}

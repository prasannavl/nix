{pkgs}: {
  helper =
    pkgs.runCommand "forgejo-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/ab/services"
      cp -R ${../.} "$repo/ab/services/forgejo"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/ab/services/forgejo/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}

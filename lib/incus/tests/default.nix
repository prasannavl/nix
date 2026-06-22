{pkgs}: {
  helper =
    pkgs.runCommand "incus-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnused
        pkgs.jq
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib"
      cp -R ${../.} "$repo/lib/incus"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/incus/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';

  module = import ./module.nix {pkgs = pkgs;};
}

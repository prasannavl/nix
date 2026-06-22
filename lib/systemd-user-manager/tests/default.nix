{pkgs}: {
  helper =
    pkgs.runCommand "systemd-user-manager-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        pkgs.python3
        pkgs.util-linux
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib"
      cp -R ${../.} "$repo/lib/systemd-user-manager"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/systemd-user-manager/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';

  module = import ./module.nix {pkgs = pkgs;};
}

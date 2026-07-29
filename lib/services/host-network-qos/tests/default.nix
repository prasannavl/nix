{pkgs}: {
  helper =
    pkgs.runCommand "host-network-qos-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib/services"
      cp -R ${../.} "$repo/lib/services/host-network-qos"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/services/host-network-qos/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';

  module = import ./module.nix {pkgs = pkgs;};
}

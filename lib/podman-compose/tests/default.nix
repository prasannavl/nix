{pkgs}: {
  helper =
    pkgs.runCommand "podman-compose-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        pkgs.procps
        pkgs.python3
        pkgs.util-linux
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib"
      cp -R ${../.} "$repo/lib/podman-compose"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/podman-compose/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';

  module = import ./module.nix {pkgs = pkgs;};
}

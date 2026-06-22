{
  pkgs,
  mkUserdataProvisioning,
}: {
  helper =
    pkgs.runCommand "stalwart-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib/services"
      cp -R ${../.} "$repo/lib/services/stalwart"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/services/stalwart/tests" \
        --pattern 'test_helper.py'
      touch "$out"
    '';

  provisioning = import ./provisioning.nix {
    inherit pkgs mkUserdataProvisioning;
  };
}

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
        pkgs.util-linux
      ];
    } ''
      cp -R ${../.} stalwart
      chmod -R u+w stalwart
      python -m unittest discover \
        --start-directory stalwart/tests \
        --pattern 'test_helper.py'
      touch "$out"
    '';

  provisioning = import ./provisioning.nix {
    inherit pkgs mkUserdataProvisioning;
  };

  lifecycle = pkgs.testers.runNixOSTest ./lifecycle.nix;
}

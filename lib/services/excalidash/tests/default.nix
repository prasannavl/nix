{pkgs}: let
  helper = (import ../default.nix {inherit pkgs;}).mkHelperScript {
    backendDataDir = "/var/lib/test-excalidash/backend";
    backendImage = "example.invalid/excalidash:fixture";
    dataDir = "/var/lib/test-excalidash";
    envFile = "/var/lib/test-excalidash/backend.env";
    migrationLockFile = "/var/lib/test-excalidash/migration.lock";
  };
in
  pkgs.runCommand "excalidash-helper-test" {
    nativeBuildInputs = [pkgs.python3 pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.util-linux];
  } ''
    test -x ${helper}/bin/excalidash-helper
    EXCALIDASH_TEST_HELPER=${../helper.sh} python ${./test_helper.py} -v
    touch "$out"
  ''

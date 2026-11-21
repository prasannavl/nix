{pkgs}:
pkgs.runCommand "pi-updater-test" {
  nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.nix pkgs.python3];
  NIX_REMOTE = "dummy://";
  NIX_CONFIG = "experimental-features = nix-command flakes";
} ''
  mkdir -p suite/tests
  cp ${../update.sh} suite/update.sh
  cp ${./test_update.py} suite/tests/test_update.py
  python suite/tests/test_update.py -v
  touch "$out"
''

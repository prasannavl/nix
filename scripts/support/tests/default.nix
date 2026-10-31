{pkgs}: let
  repo = ../../..;
in
  pkgs.runCommand "update-helper-repository-test" {
    nativeBuildInputs = [pkgs.python3];
    PYTHONDONTWRITEBYTECODE = "1";
  } ''
    python ${repo}/scripts/support/tests/test_update_helper_repository.py
    touch "$out"
  ''

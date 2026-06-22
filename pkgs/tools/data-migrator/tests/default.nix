{pkgs}: let
  python = pkgs.python3.withPackages (ps: [
    ps.pyyaml
  ]);
in {
  helper =
    pkgs.runCommand "data-migrator-helper-test" {
      nativeBuildInputs = [
        python
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/pkgs/tools"
      cp -R ${../.} "$repo/pkgs/tools/data-migrator"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/pkgs/tools/data-migrator/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}

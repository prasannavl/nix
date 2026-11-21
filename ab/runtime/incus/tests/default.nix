{pkgs}:
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
  mkdir -p "$repo/ab/runtime"
  cp -R ${../.} "$repo/ab/runtime/incus"
  chmod -R u+w "$repo"
  python -m unittest discover \
    --start-directory "$repo/ab/runtime/incus/tests" \
    --pattern 'test_*.py'
  touch "$out"
''

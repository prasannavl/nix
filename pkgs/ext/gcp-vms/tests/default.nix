{pkgs}:
pkgs.runCommand "gcp-vms-firewall-test" {
  nativeBuildInputs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.jq
  ];
} ''
  repo="$TMPDIR/repo"
  mkdir -p "$repo/pkgs/ext"
  cp -R ${../.} "$repo/pkgs/ext/gcp-vms"
  chmod -R u+w "$repo"
  bash "$repo/pkgs/ext/gcp-vms/tests/test_firewall.sh"
  touch "$out"
''

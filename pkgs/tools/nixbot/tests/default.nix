{
  pkgs,
  app,
}: {
  helper =
    pkgs.runCommand "nixbot-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.getent
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
        pkgs.inetutils
        pkgs.iproute2
        pkgs.jq
        pkgs.python3
        pkgs.procps
        pkgs.util-linux
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/pkgs/tools"
      cp -R ${../.} "$repo/pkgs/tools/nixbot"
      mkdir -p "$repo/pkgs/tools/abird-host-manager/tests/fixtures"
      cp ${../../abird-host-manager/tests/fixtures/named-routes.json} \
        "$repo/pkgs/tools/abird-host-manager/tests/fixtures/named-routes.json"
      cp ${../../../../flake.nix} "$repo/flake.nix"
      mkdir -p "$repo/pkgs"
      cp ${../../../manifest.nix} "$repo/pkgs/manifest.nix"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/pkgs/tools/nixbot/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
  runtime =
    pkgs.runCommand "nixbot-runtime-test" {
      nativeBuildInputs = [pkgs.gnugrep];
    } ''
      for command in \
        ${pkgs.findutils}/bin/find \
        ${pkgs.util-linux}/bin/flock \
        ${pkgs.gawk}/bin/awk \
        ${pkgs.gnugrep}/bin/grep \
        ${pkgs.gnused}/bin/sed \
        ${pkgs.inetutils}/bin/hostname \
        ${pkgs.getent}/bin/getent \
        ${pkgs.iproute2}/bin/ip; do
        test -x "$command"
      done
      for runtime_bin in \
        ${pkgs.findutils}/bin \
        ${pkgs.util-linux}/bin \
        ${pkgs.gawk}/bin \
        ${pkgs.gnugrep}/bin \
        ${pkgs.gnused}/bin \
        ${pkgs.inetutils}/bin \
        ${pkgs.getent}/bin \
        ${pkgs.iproute2}/bin; do
        grep -Fq "$runtime_bin" ${app}/bin/nixbot
      done
      touch "$out"
    '';
}

{pkgs}: let
  zerobyte = import ../default.nix {inherit pkgs;};
  apply = zerobyte.mkApplyScript {
    name = "zerobyte-test-apply";
    clientId = "fixture-client";
    clientSecretFile = "/definitely/missing/zerobyte-secret";
    domain = "example.test";
    discoveryEndpoint = "https://auth.example.test/.well-known/openid-configuration";
    issuerUrl = "https://auth.example.test/oauth2/openid/zerobyte";
  };
in
  pkgs.runCommand "zerobyte-helper-test" {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.gnugrep
    ];
  } ''
    test -x ${apply}/bin/zerobyte-test-apply
    ${apply}/bin/zerobyte-test-apply help > help.txt
    grep -F "Usage: zerobyte-apply apply" help.txt

    if ${apply}/bin/zerobyte-test-apply apply >stdout.txt 2>stderr.txt; then
      echo "ZeroByte apply unexpectedly succeeded without its secret" >&2
      exit 1
    fi
    grep -F "missing readable ZeroByte client secret file" stderr.txt

    touch "$out"
  ''

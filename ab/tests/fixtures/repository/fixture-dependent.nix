{
  ab,
  pkgs,
  ...
}:
ab.package.withDeps {
  fixture = ./fixture.nix;
} ({fixture}:
    pkgs.runCommand "ab-repo-fixture-dependent" {
      passthru.fixture = fixture;
    } ''
      touch "$out"
    '')

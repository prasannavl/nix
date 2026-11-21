{
  pkgs,
  ab,
  dependency ? ./base.nix,
}:
ab.package.withDeps {dependency = dependency;} ({dependency}:
    pkgs.runCommand "ab-package-scope-dependent" {
      passthru = {dependency = dependency;};
    } ''
      touch "$out"
    '')

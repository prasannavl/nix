{
  ab,
  pkgs,
  ...
}:
ab.package.withDeps {
  base = ./package.nix;
} ({base}:
    pkgs.runCommand "ab-external-repo-dependent" {
      passthru.base = base;
    } ''
      mkdir -p "$out"
      printf '%s\n' ${builtins.toJSON "external-repo-dependent"} >"$out/name"
    '')

{
  pkgs,
  ab,
}:
pkgs.runCommand "ab-package-scope-fixture" {
  passthru = {
    contextNames = builtins.attrNames ab;
    marker = pkgs.scopeMarker;
  };
} ''
  touch "$out"
''

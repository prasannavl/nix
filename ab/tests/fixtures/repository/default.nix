{
  root = ./.;
  tasks = {
    fmtScript = ./fmt.sh;
    lintScript = ./lint.sh;
  };
  checksFor = {
    pkgs,
    packageSet,
    ...
  }: {
    fixture-repository = assert builtins.attrNames packageSet == ["fixture" "fixture-alias" "fixture-dependent"];
      pkgs.runCommand "ab-repo-fixture-check" {} ''
        touch "$out"
      '';
  };
  manifest.packages = {
    fixture = {
      path = ./fixture.nix;
      aliases = ["fixture-alias"];
      rootApp = true;
    };
    fixture-dependent = ./fixture-dependent.nix;
  };
}

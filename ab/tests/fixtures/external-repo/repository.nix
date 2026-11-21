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
    external-repository = assert builtins.attrNames packageSet == ["base" "base-alias" "dependent"];
      pkgs.runCommand "ab-external-repository-check" {} ''
        touch "$out"
      '';
  };

  manifest.packages = {
    base = {
      path = ./package.nix;
      aliases = ["base-alias"];
      rootApp = true;
    };

    dependent = ./dependent.nix;
  };
}

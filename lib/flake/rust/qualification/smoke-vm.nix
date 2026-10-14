{
  pkgs,
  checkDeterminism ? false,
}: let
  # Guest instantiation avoids importing compiler bootstrap recipe closures.
  args = {
    pkgsPath = toString pkgs.path;
    system = pkgs.stdenv.hostPlatform.system;
  };
  cases = import ./smoke-recipes.nix args;
  recipeExpression = pkgs.writeText "rust-foundation-smoke-recipes.nix" ''
    import ${./smoke-recipes.nix} (builtins.fromJSON ${builtins.toJSON (builtins.toJSON args)})
  '';
in
  import ./vm-test.nix {
    inherit pkgs recipeExpression checkDeterminism;
    name = "rust-foundation-vm-smoke";
    inherit (cases) baseline changed;
    seedPaths = [(builtins.storePath (toString pkgs.path)) pkgs.stdenvNoCC pkgs.bash pkgs.coreutils];
    memorySize = 16384;
    cores = 16;
  }

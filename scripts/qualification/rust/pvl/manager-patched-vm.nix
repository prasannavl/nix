# Optional qualification entrypoint. Only this explicit import chooses patched
# Cargo; root flake checks, system packages and the normal VM route stay regular.
{
  pkgs,
  pkgsPath,
  cranePath,
  recipeSupportSrc,
  baselineSrc,
  changedSrc,
  name ? "rust-foundation-manager-patched-cargo-vm",
  memorySize ? 16384,
  cores ? 16,
  buildTimeout ? 300,
  checkDeterminism ? true,
}: let
  qualificationToolingSrc =
    /.
    + builtins.unsafeDiscardStringContext (builtins.toString (builtins.path {
      path = ../../../../lib/flake/rust/qualification;
      name = "rust-foundation-qualification-cargo-support";
      filter = path: _type: builtins.elem (builtins.baseNameOf path) ["patched-cargo.nix" "cargo-dep-info-order-16691.patch"];
    }));
  recipeArguments = {
    inherit pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc qualificationToolingSrc;
    system = pkgs.stdenv.hostPlatform.system;
  };
  recipes = import ./manager-recipes.nix recipeArguments;
in
  import ./manager-vm.nix {
    inherit pkgs pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc qualificationToolingSrc name memorySize cores buildTimeout checkDeterminism;
    seedPaths = import ../../../../lib/flake/rust/qualification/recipe-seeds.nix {
      producers = recipes.seedInputProducers;
      excludedOutputs = recipes.excludedOutputs;
      extraInputs = builtins.attrValues recipes.inputs.compilerTools ++ recipes.inputs.fleetRuntimeInputs ++ [recipes.inputs.vendor];
    };
  }

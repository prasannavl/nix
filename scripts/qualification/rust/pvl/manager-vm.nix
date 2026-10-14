# Repository-owned original manager scenario; generic VM execution is injected.
{
  pkgs,
  pkgsPath,
  cranePath,
  recipeSupportSrc,
  baselineSrc,
  changedSrc,
  seedPaths,
  qualificationToolingSrc ? null,
  name ? "rust-foundation-manager-vm",
  memorySize ? 16384,
  cores ? 16,
  buildTimeout ? 300,
  checkDeterminism ? false,
  baselineRuntimeChecks ? [],
  changedRuntimeChecks ? [],
}: let
  vm = import ../../../../lib/flake/rust/qualification/recipe-vm.nix {
    inherit pkgs pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc seedPaths;
    inherit qualificationToolingSrc name memorySize cores buildTimeout checkDeterminism;
    inherit baselineRuntimeChecks changedRuntimeChecks;
    recipeFile = ./manager-recipes.nix;
    recipeLabel = "rust-foundation-manager";
    preservedFiles = [
      "Cargo.toml"
      "Cargo.lock"
      ".cargo/config"
      ".cargo/config.toml"
      "pkgs/tools/abird-host-agent/Cargo.toml"
      "pkgs/tools/abird-host-agent/default.nix"
      "pkgs/tools/abird-host-manager/Cargo.toml"
      "pkgs/tools/abird-host-manager/default.nix"
    ];
  };
in
  vm
  // {
    passthru =
      (vm.passthru or {})
      // {
        managerQualification = vm.passthru.recipeQualification;
      };
  }

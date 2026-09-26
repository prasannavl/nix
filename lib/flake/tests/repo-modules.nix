{pkgs}: let
  inherit (pkgs) lib;
  stacks = {
    alpha.stackName = "alpha";
    beta.stackName = "beta";
  };
  repoModules = {
    repo.base = ../default.nix;
    stacks = {
      alpha.feature = ../root.nix;
      beta.feature = ../packages.nix;
    };
  };
  composition = import ../repo-modules.nix {
    inherit lib repoModules stacks;
  };
  paths = modules: map toString modules;
  repoPath = toString ../default.nix;
  alphaPath = toString ../root.nix;
  betaPath = toString ../packages.nix;
  invalid = repoModules:
    builtins.tryEval (builtins.deepSeq (import ../repo-modules.nix {
        inherit lib repoModules stacks;
      })
      true);
  unknownEffectiveStack = builtins.tryEval (builtins.deepSeq (composition.modulesFor {stackName = "missing";}) true);
  malformedEffectiveStack = builtins.tryEval (builtins.deepSeq (composition.modulesFor {stackName = 1;}) true);
  missingEffectiveStackName = builtins.tryEval (builtins.deepSeq (composition.modulesFor {}) true);
  nonAttributeEffectiveStack = builtins.tryEval (builtins.deepSeq (composition.modulesFor "alpha") true);
in
  assert paths (composition.modulesFor null) == [repoPath];
  assert paths (composition.modulesFor {stackName = "alpha";}) == [repoPath alphaPath];
  assert paths (composition.modulesFor {stackName = "beta";}) == [repoPath betaPath];
  assert !(invalid {unexpected = {};}).success;
  assert !(invalid {stacks.missing.feature = ../root.nix;}).success;
  assert !(invalid {stacks.shared.feature = ../root.nix;}).success;
  assert !(invalid {repo.feature = {};}).success;
  assert !(invalid {repo.missing = /definitely-missing-repository-module.nix;}).success;
  assert !(invalid {
    repo = {
      first = ../default.nix;
      second = ../default.nix;
    };
  }).success;
  assert !(invalid {
    repo.feature = ../default.nix;
    stacks.alpha.feature = ../root.nix;
  }).success;
  assert !(invalid {
    repo.base = ../default.nix;
    stacks.alpha.feature = ../default.nix;
  }).success;
  assert !(invalid {
    stacks.alpha.feature = ../root.nix;
    stacks.beta.feature = ../root.nix;
  }).success;
  assert !unknownEffectiveStack.success;
  assert !malformedEffectiveStack.success;
  assert !missingEffectiveStackName.success;
  assert !nonAttributeEffectiveStack.success;
    pkgs.runCommand "lib-flake-repo-modules-test" {} ''
      touch "$out"
    ''

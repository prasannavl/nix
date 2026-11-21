{pkgs}: let
  inherit (pkgs) lib;
  repoComponent = import ../../../ab/repo {core = import ../../../ab/core;};
  stacks = {
    alpha.name = "alpha";
    beta.name = "beta";
  };
  repoModules = {
    repo.base = ../../../lib/default.nix;
    stacks = {
      alpha.feature = ../../../lib/root.nix;
      beta.feature = ../../../ab/core/packaging/apps.nix;
    };
  };
  composition = repoComponent.modules {
    inherit lib repoModules stacks;
  };
  paths = modules: map toString modules;
  repoPath = toString ../../../lib/default.nix;
  alphaPath = toString ../../../lib/root.nix;
  betaPath = toString ../../../ab/core/packaging/apps.nix;
  invalid = repoModules:
    builtins.tryEval (builtins.deepSeq (repoComponent.modules {
        inherit lib repoModules stacks;
      })
      true);
  unknownEffectiveStack = builtins.tryEval (builtins.deepSeq (composition.modulesFor {name = "missing";}) true);
  malformedEffectiveStack = builtins.tryEval (builtins.deepSeq (composition.modulesFor {name = 1;}) true);
  missingEffectiveStackName = builtins.tryEval (builtins.deepSeq (composition.modulesFor {}) true);
  nonAttributeEffectiveStack = builtins.tryEval (builtins.deepSeq (composition.modulesFor "alpha") true);
in
  assert paths (composition.modulesFor null) == [repoPath];
  assert paths (composition.modulesFor {name = "alpha";}) == [repoPath alphaPath];
  assert paths (composition.modulesFor {name = "beta";}) == [repoPath betaPath];
  assert !(invalid {unexpected = {};}).success;
  assert !(invalid {stacks.missing.feature = ../../../lib/root.nix;}).success;
  assert !(invalid {stacks.shared.feature = ../../../lib/root.nix;}).success;
  assert !(invalid {repo.feature = {};}).success;
  assert !(invalid {repo.missing = /definitely-missing-repository-module.nix;}).success;
  assert !(invalid {
    repo = {
      first = ../../../lib/default.nix;
      second = ../../../lib/default.nix;
    };
  }).success;
  assert !(invalid {
    repo.feature = ../../../lib/default.nix;
    stacks.alpha.feature = ../../../lib/root.nix;
  }).success;
  assert !(invalid {
    repo.base = ../../../lib/default.nix;
    stacks.alpha.feature = ../../../lib/default.nix;
  }).success;
  assert !(invalid {
    stacks.alpha.feature = ../../../lib/root.nix;
    stacks.beta.feature = ../../../lib/root.nix;
  }).success;
  assert !unknownEffectiveStack.success;
  assert !malformedEffectiveStack.success;
  assert !missingEffectiveStackName.success;
  assert !nonAttributeEffectiveStack.success;
    pkgs.runCommand "lib-flake-repo-modules-test" {} ''
      touch "$out"
    ''

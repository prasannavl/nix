{
  core,
  repository ? null,
}:
assert core.name == "ab-core"; let
  validation = core.validation;
  cache = import ./cache.nix {inherit validation;};
  importDirectory = import ./import-directory.nix;
  serviceProjections = {serviceStack}: let
    layout = import ./service-projection-repository.nix {
      inherit importDirectory serviceStack validation;
    };
    placements = import ./service-placements.nix {
      inherit serviceStack validation;
    };
    admission = import ./service-placement-admission.nix {
      inherit serviceStack validation;
    };
    moves = import ./service-moves.nix {
      inherit serviceStack validation;
      validationPaths = core.validationPaths;
    };
    adapters = import ./service-projection-adapters.nix {
      inherit admission moves placements;
    };
  in {
    inherit admission adapters layout moves placements;
  };
  projections = {
    specifications = import ./projection-domain-specifications.nix;
    fold = import ./projection-domain-fold.nix {
      inherit validation;
      validationPaths = core.validationPaths;
    };
    services = serviceProjections;
  };
  fold = import ./repository-fold.nix {inherit validation;};
  config = import ./repository-config.nix {
    inherit cache fold validation;
    builtInProjectionDomains = projections.specifications;
  };
  inputSets = {lib}: import ./input-sets.nix {inherit lib;};
  modules = import ./modules.nix {inherit validation;};
  projectionDomains = args:
    import ./projection-domains.nix ({repoProjections = projections;} // args);
  flake = {
    outputs = args: import ./flake-outputs.nix args;
    self = args: import ./self-flake.nix args;
  };
  runtimeCloseouts = args: import ./runtime-closeouts.nix args;

  boundRepository = assert repository != null;
  assert repository ? root;
  assert repository ? manifest;
  assert repository.manifest ? packages; repository;
  checksFor = boundRepository.checksFor or null;
  externalPackagesFor = boundRepository.externalPackagesFor or (_system: {});
  taskConfig = boundRepository.tasks or null;
  treefmtConfig = boundRepository.treefmtConfig or null;

  packagesFor = pkgs: let
    packagePkgs = core.packageScope {
      pkgs = pkgs;
      projectRoot = boundRepository.root;
      inherit treefmtConfig;
    };
  in
    import ./packages.nix {
      ab = packagePkgs.ab;
      inherit externalPackagesFor validation;
      manifest = boundRepository.manifest;
      pkgs = packagePkgs;
    };

  extension = {
    pkgs,
    ab,
  }: let
    packages = packagesFor pkgs;
  in {
    repo =
      {
        root = boundRepository.root;
        inherit packages;
      }
      // (
        if taskConfig == null
        then {}
        else {
          tasks = import ./tasks.nix {
            inherit ab pkgs;
            packageSet = packages.stdPackages;
            inherit (taskConfig) fmtScript lintScript;
          };
        }
      )
      // (
        if checksFor == null
        then {}
        else {
          checks = import ./checks.nix {
            inherit checksFor pkgs;
            packageSet = packages.packages;
          };
        }
      );
  };
in {
  name = "ab-repo";
  dependencies = {
    required = ["core"];
    optional = [];
  };

  inherit cache config extension flake fold importDirectory inputSets modules packagesFor projectionDomains projections runtimeCloseouts;
}

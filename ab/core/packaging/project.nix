{
  packageScope,
  projectRoot ? null,
  treefmtConfig ? null,
}: let
  scopeFor = pkgs:
    packageScope {
      inherit pkgs projectRoot treefmtConfig;
    };

  defaultPackageFor = {
    pkgs,
    packageFile,
    args ? {},
  }:
    (scopeFor pkgs).callPackage packageFile args;

  mkFlakeOutputs = packageFile: declaredInputs @ {
    nixpkgs,
    flake-utils,
    defaultSystem ? builtins.head flake-utils.lib.defaultSystems,
    systems ? flake-utils.lib.defaultSystems,
    overlays ? [],
    crane ? null,
    rustToolchainInputs ? {},
    rustToolchainProviders ? {},
    rustWorkspaceDeps ? null,
    pkgsForSystem ? null,
    packageFor ? null,
    stdFlakeOutputArgs ? _: {},
    libExports ? _: {},
    ...
  }: let
    toolchainInputs =
      declaredInputs
      // rustToolchainInputs
      // (
        if crane == null
        then {}
        else {inherit crane;}
      );
    toolchainOverlays = import ./toolchains.nix {
      inputs = toolchainInputs;
      providers.rust = rustToolchainProviders;
    };
    hasProviderInput =
      builtins.any
      (name: builtins.hasAttr name declaredInputs)
      ["go-overlay" "fenix" "rust-overlay" "rust-nixpkgs"];
    needsImport =
      overlays
      != []
      || rustToolchainInputs != {}
      || rustToolchainProviders != {}
      || hasProviderInput
      || (builtins.tryEval (crane != null)).value;

    pkgsFor = system:
      if pkgsForSystem != null
      then pkgsForSystem system
      else if
        !needsImport
        && builtins.isAttrs nixpkgs
        && nixpkgs ? legacyPackages
        && builtins.hasAttr system nixpkgs.legacyPackages
      then nixpkgs.legacyPackages.${system}
      else
        import nixpkgs {
          inherit system;
          overlays = toolchainOverlays ++ overlays;
        };

    withWorkspacePolicy = pkgs:
      if rustWorkspaceDeps == null || (pkgs.rustWorkspaceDeps or null) == rustWorkspaceDeps
      then pkgs
      else if pkgsForSystem != null
      then throw "mkFlakeOutputs: rustWorkspaceDeps disagrees with pkgsForSystem's complete package set; configure rustWorkspaceDeps in pkgsForSystem instead"
      else pkgs.extend (_final: _prev: {inherit rustWorkspaceDeps;});

    outputsFor = pkgsInput: let
      policyPkgs = withWorkspacePolicy pkgsInput;
      pkgs = scopeFor policyPkgs;
      ab = pkgs.ab;
      build =
        if packageFor == null
        then pkgs.callPackage packageFile {}
        else
          packageFor {
            pkgs = policyPkgs;
            packageFile = packageFile;
          };
      flakeOutputs = ab.flake.outputs ({
          inherit pkgs build;
        }
        // stdFlakeOutputArgs {
          inherit ab pkgs build;
        });
      nixosModules = ab.flake.modules {inherit build;};
    in
      # Validate even when an injected packageFor ignores its pkgs argument.
      builtins.seq policyPkgs {
        inherit flakeOutputs nixosModules;
        library = libExports {
          pkgs = policyPkgs;
          inherit ab build;
        };
      };

    # Share one lazy output record per system, including the module-export
    # system when it is not in systems. Duplicate keys keep the first thunk.
    outputsBySystem = builtins.listToAttrs (map (system: {
      name = system;
      value = outputsFor (pkgsFor system);
    }) (systems ++ [defaultSystem]));
    defaultOutputs = outputsBySystem.${defaultSystem};
  in
    if pkgsForSystem != null && (overlays != [] || rustToolchainInputs != {} || rustToolchainProviders != {})
    then throw "mkFlakeOutputs: pkgsForSystem supplies the complete package set; overlays, rustToolchainInputs and rustToolchainProviders must be configured there instead"
    else
      flake-utils.lib.eachSystem systems (system: let
        output = outputsBySystem.${system};
      in
        if !builtins.isAttrs output.library
        then throw "mkFlakeOutputs: libExports must return an attribute set"
        else
          # A complete injected package set must not force the nixpkgs input.
          output.flakeOutputs
          // (
            if output.library == {}
            then {}
            else {lib = output.library;}
          ))
      // (
        if defaultOutputs.nixosModules == {}
        then {}
        else {nixosModules = defaultOutputs.nixosModules;}
      );
in {
  packageFor = defaultPackageFor;
  inherit mkFlakeOutputs;
}

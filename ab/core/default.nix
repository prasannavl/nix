rec {
  name = "ab-core";
  dependencies = {
    required = [];
    optional = [];
  };

  validation = import ./validation;
  validationPaths = {lib}: import ./validation/paths.nix {inherit lib;};
  registryModule = ./nixos/registry.nix;
  toolchainOverlays = args: import ./packaging/toolchains.nix args;
  flake = {
    apps = import ./packaging/apps.nix;
    devShells = {lib}: import ./packaging/dev-shells.nix {inherit lib;};
  };
  packageScope = {
    pkgs,
    projectRoot ? null,
    treefmtConfig ? null,
  }: let
    scope = import ./packaging/scope.nix {
      pkgs = pkgs;
      ab = mk {
        pkgs = scope;
        inherit projectRoot treefmtConfig;
      };
    };
  in
    scope;

  project = {
    projectRoot ? null,
    treefmtConfig ? null,
  }:
    import ./packaging/project.nix {
      inherit packageScope projectRoot treefmtConfig;
    };

  mk = {
    pkgs,
    projectRoot ? null,
    treefmtConfig ? null,
    extensions ? [],
  }:
    assert pkgs ? lib; let
      helper = import ./packaging/pkg-helper.nix {
        inherit projectRoot treefmtConfig;
      };
      rebind = args:
        mk (
          args
          // {
            inherit extensions;
          }
        );
      nixos = import ./nixos/service.nix {
        mkCore = rebind;
        inherit projectRoot treefmtConfig;
      };
      packagePkgs = import ./packaging/scope.nix {
        pkgs = pkgs;
        ab = bound;
      };
      base = {
        # The low-level package-set seam remains authoritative. Keeping this
        # binding lazy lets a core context be constructed from plain Nixpkgs;
        # resolver use requires composition to install pkgs.toolchains.
        toolchains = pkgs.toolchains;

        build = {
          rust = helper.mkRustDerivation;
          cargoWorkspace = helper.mkCargoWorkspacePackage;
          crane = helper.mkCraneRustPackage;
          go = helper.mkGoDerivation;
          python = helper.mkPythonDerivation;
          web = helper.mkWebDerivation;
          staticWeb = helper.mkStaticWebDerivation;
          shell = helper.mkShellScriptDerivation;
          aggregate = helper.mkAggregateDerivation;
          trunk = helper.mkTrunkProject;
        };

        package = {
          wire = helper.wirePassthru;
          check = helper.mkCheck;
          checks = helper.mkChecks;
          withDeps = import ./packaging/with-deps.nix {
            inherit (packagePkgs) callPackage;
          };
          ops = {
            bundle = helper.mkPackageOpsBundle;
            strip = helper.stripPkgOp;
            collectInputs = helper.collectPkgOpInputs;
            manifest = helper.pkgOpsManifest;
            runtimeInputs = helper.pkgOpsRuntimeInputs;
            supported = helper.isSupportedOnCurrentSystem;
          };
        };

        tasks = {
          nix = {
            fmt = helper.alejandraFmt;
            fmtCheck = helper.alejandraCheck;
          };
          deno = {
            fmt = helper.denoFmt;
            fmtCheck = helper.denoFmtCheck;
          };
          node = {
            fmt = helper.biomeFmt;
            fmtCheck = helper.biomeFmtCheck;
            lint = helper.biomeLint;
            lintFix = helper.biomeLintFix;
            projectFmt = helper.projectFmtBiome;
            projectFmtCheck = helper.projectCheckFmtBiome;
            projectLint = helper.projectLintBiome;
            projectLintFix = helper.projectLintFixBiome;
          };
          python = {
            fmt = helper.ruffFmt;
            fmtCheck = helper.ruffFmtCheck;
            lint = helper.ruffLint;
            lintFix = helper.ruffLintFix;
            projectFmt = helper.projectFmtRuff;
            projectFmtCheck = helper.projectCheckFmtRuff;
            projectLint = helper.projectLintRuff;
            projectLintFix = helper.projectLintFixRuff;
          };
          go = {
            fmt = helper.goFmt;
            fmtCheck = helper.goFmtCheck;
            lint = helper.goLint;
            test = helper.goTest;
            projectFmt = helper.projectFmtGo;
            projectFmtCheck = helper.projectCheckFmtGo;
            projectLint = helper.projectLintGo;
            projectTest = helper.projectTestGo;
          };
          rust = {
            fmt = helper.rustFmt;
            test = helper.rustTest;
            clippy = helper.rustClippy;
            projectFmt = helper.projectFmtRust;
            projectLintFix = helper.projectLintFixRust;
          };
          shell = {
            fmt = helper.shfmtFmt;
            fmtCheck = helper.shfmtCheck;
            projectLint = helper.projectLintShell;
          };
        };

        flake = {
          app = helper.mkPackageApp;
          modules = helper.mkNixosModuleAttrs;
          outputs = helper.mkStdFlakeOutputs;
        };

        inherit nixos;
      };
      bound = builtins.foldl' applyExtension base extensions;
      applyExtension = ab: extension: let
        contribution = extension {
          inherit pkgs ab;
        };
      in
        if !builtins.isAttrs contribution
        then throw "ab-core: extension must return an attribute set"
        else (validation.mk "ab-core").mergeUniqueAttrs "extension namespaces" [ab contribution];
    in
      bound;
}

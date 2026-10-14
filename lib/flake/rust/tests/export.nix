# Recording constructor tests; no Cargo or producer qualification inferred.
let
  src = ./fixtures/exports;
  dirs = ["members/agent" "members/manager"];
  isDerivation = value: builtins.isAttrs value && (value.type or null) == "derivation";
  lib = {
    inherit isDerivation;
    callPackageWith = scope: file: explicit: let
      fn = import file;
    in
      fn ((builtins.intersectAttrs (builtins.functionArgs fn) scope) // explicit);
  };
  pkgs = {
    inherit lib;
    pkgs = throw "original self reference must not be used";
  };
  makeBase = member: {
    type = "derivation";
    drvPath = "${member}-base.drv";
    outputName = "out";
    outPath = "${member}-base";
    marker = member;
  };
  recordingHelper = {
    forRustSource = scope: let
      helper = {
        rustPlan = _: scope.memberDirs;
        mkRustDerivation = args: {
          type = "derivation";
          drvPath = "${args.pname}.drv";
          passthru =
            (args.extraPassthru or {})
            // {
              projectDir = args.projectDir;
              base = args.base or null;
              dependencies = args.internalDeps or [];
              sourceScope = scope;
              effectiveSrc = args.src or null;
              deps = args.deps or [];
            };
        };
        mkRustComposition = context: let
          closures = {
            "members/agent" = ["members/agent"];
            "members/manager" = dirs;
          };
        in {
          diagnostics.topology.plan.closureDirs = closures;
          mkRustDerivation = args:
            helper.mkRustDerivation (context
              // args
              // (
                if args ? base || (args.useWorkspaceDeps or true) == false
                then {}
                else {
                  base = makeBase args.projectDir;
                  deps = builtins.filter (dir: dir != args.projectDir) closures.${args.projectDir};
                }
              ));
        };
      };
    in
      helper;
  };
  exporter = import ../export.nix {
    inherit src;
    memberDirs = dirs;
    packageFile = src + "/members/manager/default.nix";
  };
  make = extra:
    exporter.mkPackage ({
        inherit pkgs;
        pkgHelper = recordingHelper;
        stack.org = "consumer-context";
      }
      // extra);
  default = make {};
  agent = builtins.head default.passthru.dependencies;
  external = {
    type = "derivation";
    drvPath = "external-base.drv";
    outputName = "out";
    outPath = "external-base";
  };
  injected = make {base = external;};
  override = {
    type = "derivation";
    marker = "explicit-dependency";
  };
  fails = value: !(builtins.tryEval value).success;
  assertions = {
    originalDefinitionCalled = default.passthru.projectDir == "members/manager";
    originalSiblingDefault = agent.passthru.projectDir == "members/agent";
    pkgsSelfContextPreserved = agent.passthru.stackMarker == "consumer-context";
    bothHelperRoutesScoped = agent.passthru.bothHelperRoutes == dirs;
    sameSourceScope = agent.passthru.sourceScope.memberDirs == default.passthru.sourceScope.memberDirs;
    automaticMemberBase = default.passthru.base.marker == "members/manager";
    siblingOwnBase = agent.passthru.base.marker == "members/agent";
    selectedExternalOverride = injected.passthru.base.drvPath == external.drvPath;
    externalNotAppliedToSibling = (builtins.head injected.passthru.dependencies).passthru.base.marker == "members/agent";
    nullMeansAutomatic = (make {base = null;}).passthru.base.marker == "members/manager";
    explicitDependencyDefaultOverride = (make {packageArgs.agent = override;}).passthru.dependencies == [override];
    sourceOnlyNullDefaultPreserved = (make {packageArgs.agent = null;}).passthru.dependencies == [];
    reservedPkgContextRejected = fails (make {packageArgs.pkgs = {};});
    reservedStackContextRejected = fails (make {packageArgs.stack = {};});
    reservedHelperContextRejected = fails (make {packageArgs.pkgHelper = {};});
    nonDerivationBaseRejected = fails (make {base = "opaque";});
    reservedCallPackageContextRejected = fails (make {packageArgs.callPackage = _: {};});
    missingSrcDefaultBound = (make {packageArgs.omitSrc = true;}).passthru.effectiveSrc == src;
    missingSrcExplicitBaseBound =
      (make {
        base = external;
        packageArgs.omitSrc = true;
      }).passthru.effectiveSrc
      == src;
    nullDependencyExplicitBaseSourceClosure =
      (make {
        base = external;
        packageArgs.agent = null;
      }).passthru.deps
      == (make {packageArgs.agent = null;}).passthru.deps;
    recipeNullRemainsEscape = (make {packageArgs.buildArgs.base = null;}).passthru.base == null;
    recipeWorkspaceEscapePreserved = (make {packageArgs.buildArgs.useWorkspaceDeps = false;}).passthru.base == null;
    matchingIntrinsicBaseAdmitted =
      (make {
        base = external;
        packageArgs.buildArgs.base = external;
      }).passthru.base
      == external;
    conflictingIntrinsicDrvPathRejected = fails (make {
      base = external;
      packageArgs.buildArgs.base = external // {drvPath = "other.drv";};
    });
    conflictingIntrinsicOutputNameRejected = fails (make {
      base = external;
      packageArgs.buildArgs.base = external // {outputName = "other";};
    });
    conflictingIntrinsicOutPathRejected = fails (make {
      base = external;
      packageArgs.buildArgs.base = external // {outPath = "other";};
    });
    opaqueIntrinsicBaseRejected = fails (make {
      base = external;
      packageArgs.buildArgs.base = builtins.removeAttrs external ["type"];
    });
    outsideDefinitionRejected =
      fails
      (import ../export.nix {
        inherit src;
        memberDirs = dirs;
        packageFile = src + "/members/peer/default.nix";
      }).member;
    stackRouteExport =
      (import ../export.nix {
        inherit src;
        memberDirs = dirs;
        packageFile = src + "/members/agent/default.nix";
      }).mkPackage {
        inherit pkgs;
        pkgHelper = recordingHelper;
        stack.org = "stack-route";
      }
      != null;
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-export failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }

# Pure policy tests: recording helpers do not establish artifact qualification.
let
  recorder = {
    rustPlan = (import ../rust-closures.nix).plan;
    consumerContext = _: {
      compileAttrs = {};
      packagingAttrs = {};
    };
    mkClosureBase = args: args // {type = "derivation";};
    mkRustDerivation = args: args;
  };
  compose = (import ../member-bases.nix) {pkgHelper = recorder;};
  fixture = ./fixtures/rust-composition;
  context = {
    pkgs = {};
    src = fixture;
  };
  factory = mode: compose (context // {baseMode = mode;});
  member = factory "member";
  app = "members/application";
  args = {
    projectDir = app;
    pname = "application";
  };
  selected = member.mkRustDerivation args;
  opaque = {
    type = "derivation";
    marker = "caller";
  };
  fails = value: !(builtins.tryEval value).success;
  noPlan = mode:
    compose {
      pkgs = {};
      src = throw "planner must stay lazy";
      baseMode = mode;
    };
  assertions = {
    omittedPolicy = (factory null).mkRustDerivation args == (context // {toolchain = null;} // args);
    unionPolicy = (factory "union").mkRustDerivation args == (factory null).mkRustDerivation args;
    selectorRejected = fails (factory "legacy");
    explicitWorkspaceDisableHonored = builtins.all (mode:
      (factory mode).mkRustDerivation (args // {useWorkspaceDeps = false;})
      == (context // {toolchain = null;} // args // {useWorkspaceDeps = false;})) [null "member" "union"];
    disabledPolicyUnchanged =
      ((compose {
          pkgs.rustWorkspaceDeps = false;
          src = fixture;
          baseMode = "union";
        }).mkRustDerivation
        args).pkgs.rustWorkspaceDeps
      == false;
    explicitFalseEscapes = !((noPlan "member").mkRustDerivation (args // {useWorkspaceDeps = false;})) ? base;
    explicitNullEscapes = ((noPlan "member").mkRustDerivation (args // {base = null;})).base == null;
    explicitBaseWins = builtins.all (mode: ((noPlan mode).mkRustDerivation (args // {base = opaque;})).base.marker == "caller") [null "union" "member"];
    explicitBaseFalseWins = builtins.all (mode: let
      chosen = (noPlan mode).mkRustDerivation (args
        // {
          base = opaque;
          useWorkspaceDeps = false;
        });
    in
      chosen.base == opaque && !chosen.useWorkspaceDeps) [null "union" "member"];
    escapesPreserveDeps =
      ((noPlan "member").mkRustDerivation (args
        // {
          base = null;
          deps = ["uninterpreted"];
        })).deps
      == ["uninterpreted"];
    nonMemberBaseForLazy = builtins.all (mode: (noPlan mode).baseFor (throw "member must stay lazy") == null) [null "union"];
    diagnosticsModeLazy = (noPlan "member").diagnostics.requestedMode == "member";
    invalidModeRejected = fails (factory "component");
    perMemberModeRejected = fails ((factory null).mkRustDerivation (args // {baseMode = "legacy";}));
    completeClosure = selected.deps == ["members/branch" "members/leaf" "members/middle"];
    partialDepsCompleted = (member.mkRustDerivation (args // {deps = ["members/middle"];})).deps == selected.deps;
    duplicateDepsCompleted = (member.mkRustDerivation (args // {deps = ["members/leaf" "members/leaf"];})).deps == selected.deps;
    extraDepsRejected = fails (member.mkRustDerivation (args // {deps = ["members/peer"];}));
    nonListDepsRejected = fails (member.mkRustDerivation (args // {deps = "members/leaf";}));
    nonStringDepsRejected = fails (member.mkRustDerivation (args // {deps = [null];}));
    nonCanonicalDepsRejected = fails (member.mkRustDerivation (args // {deps = ["./members/leaf"];}));
    nonCanonicalMemberRejected = fails (member.mkRustDerivation (args // {projectDir = "./${app}";}));
    missingMemberRejected = fails (member.mkRustDerivation (args // {projectDir = "members/missing";}));
    nullMemberRejected = fails (member.mkRustDerivation (args // {projectDir = null;}));
    unsupportedTopologyRejected = fails ((compose {
        pkgs = {};
        src = ./fixtures/rust-closures/config;
        baseMode = "member";
      }).mkRustDerivation
      args);
    unsupportedUnionNotPlanned =
      ((compose {
          pkgs = {};
          src = ./fixtures/rust-closures/config;
          baseMode = "union";
        }).mkRustDerivation
        args).pname
      == "application";
    largestLexicalParent = selected.base.parent.projectDir == "members/branch";
    depthThree = selected.base.parent.parent.projectDir == "members/leaf" && selected.base.parent.parent.parent == null;
    fanInOneParent = selected.base.parent.deps == ["members/leaf"];
    singletonNoParent = (member.baseFor "members/peer").parent == null;
    equalClosureCycleNoParents = (member.baseFor "members/cycle-a").parent == null && (member.baseFor "members/cycle-b").parent == null;
    equalClosureIncludesBoth = (member.baseFor "members/cycle-a").deps == ["members/cycle-b"];
    diagnosticsMatch = member.diagnostics.parents.${app} == "members/branch" && member.diagnostics.parents."members/leaf" == null;
    internalDepsPreserved = (member.mkRustDerivation (args // {internalDeps = [opaque];})).internalDeps == [opaque];
    noPolicyLeakage = !(selected ? baseMode) && !(selected ? diagnostics);
    defaultContext = selected.pkgs == {} && selected.src == fixture && selected.toolchain == null;
    explicitContextPreserved =
      (member.mkRustDerivation (args
        // {
          pkgs.marker = "explicit";
          toolchain.provider = "resolved";
        })).pkgs.marker
      == "explicit";
    baseUsesActualCompilerContext = let
      effective = {
        pkgs.marker = "consumer";
        toolchain.provider = "resolved";
      };
      chosen = member.mkRustDerivation (args // effective);
    in
      builtins.all (base: base.pkgs == effective.pkgs && base.toolchain == effective.toolchain && base.src == fixture) [chosen.base chosen.base.parent chosen.base.parent.parent];
    baseForRetainsFactoryCompilerContext = (member.baseFor app).pkgs == context.pkgs && (member.baseFor app).toolchain == null;
    labelPreserved = (member.mkRustDerivation (args // {baseLabel = "diagnostic";})).baseLabel == "diagnostic";
    nullEscapeDoesNotForceArguments =
      ((noPlan "member").mkRustDerivation {
        pname = "escape";
        base = null;
        projectDir = throw "projectDir must stay lazy";
        deps = throw "deps must stay lazy";
        internalDeps = throw "internalDeps must stay lazy";
      }).pname
      == "escape";
    falseEscapeDoesNotForceArguments =
      ((noPlan "member").mkRustDerivation {
        pname = "escape";
        useWorkspaceDeps = false;
        projectDir = throw "projectDir must stay lazy";
        deps = throw "deps must stay lazy";
        internalDeps = throw "internalDeps must stay lazy";
      }).pname
      == "escape";
    falseEscapePreservesOutsideDeps =
      ((noPlan "member").mkRustDerivation (args
        // {
          useWorkspaceDeps = false;
          deps = ["members/peer"];
        })).deps
      == ["members/peer"];
    legacyRejectedBeforeSource = fails (noPlan "legacy");
    unsupportedLegacyModeRejected = fails (compose {
      pkgs = {};
      src = ./fixtures/rust-closures/config;
      baseMode = "legacy";
    });
    legacyExplicitBaseRejected = fails ((noPlan "legacy").mkRustDerivation (args // {base = opaque;}));
    legacyExplicitNullRejected = fails ((noPlan "legacy").mkRustDerivation (args // {base = null;}));
    legacyExplicitFalseRejected = fails ((noPlan "legacy").mkRustDerivation (args // {useWorkspaceDeps = false;}));
    legacyBaseForRejected = fails ((noPlan "legacy").baseFor (throw "member must stay lazy"));
    legacyBaseForUnsupportedStringRejected = fails ((compose {
        pkgs = {};
        src = ./fixtures/rust-closures/config;
        baseMode = "legacy";
      }).baseFor
      "members/not-declared");
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-composition failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }

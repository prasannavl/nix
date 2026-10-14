# Policy/composition only: the helper owns source, vendor and admission recipes.
# This private dependency is supplied by pkg-helper, not a provider-routing API.
{pkgHelper}: {
  pkgs,
  src,
  toolchain ? null,
  baseMode ? null,
  buildAttrs ? {},
}: let
  fail = message: throw "pkg-helper.mkRustComposition: ${message}";
  modeGuard =
    if builtins.elem baseMode [null "member" "union"]
    then true
    else fail "baseMode must be member or union (omit it to preserve policy)";
  topology = pkgHelper.rustPlan {src = src;};
  topologyGuard =
    if topology.supported
    then true
    else fail "member mode requires a supported declared-source workspace; choose union or explicitly disable workspace dependencies";
  memberGuard = member:
    if !builtins.isString member || !(builtins.elem member topology.plan.members)
    then fail "member mode requires a canonical declared projectDir"
    else true;
  parentFor = member: let
    candidates = topology.plan.parentCandidates.${member};
  in
    if candidates == []
    then null
    else builtins.head candidates;
  # The planner's strict size decrease prevents cycles, including equal-closure
  # Cargo dependency cycles. Use its deterministic largest/lexical order as-is.
  # Source topology belongs to the factory. Compiler/library selection belongs
  # to the effective consumer, including per-call toolchain/package-set changes.
  contextualBases = producerContext: compilerAttrs: let
    bases = builtins.listToAttrs (map (member: let
        parent = parentFor member;
      in {
        name = member;
        value = pkgHelper.mkClosureBase {
          src = src;
          pkgs = producerContext.pkgs;
          toolchain = producerContext.toolchain or null;
          buildAttrs = compilerAttrs;
          projectDir = member;
          deps = builtins.filter (dir: dir != member) topology.plan.closureDirs.${member};
          parent =
            if parent == null
            then null
            else bases.${parent};
        };
      })
      topology.plan.members);
  in
    bases;
  factoryContext =
    {inherit pkgs src toolchain;}
    // (
      if buildAttrs == {}
      then {}
      else {inherit buildAttrs;}
    );
  factoryCompilerAttrs = (pkgHelper.consumerContext factoryContext).compileAttrs;
  bases = contextualBases factoryContext factoryCompilerAttrs;
  baseFor = member:
    builtins.seq modeGuard (
      if baseMode != "member"
      then null
      else builtins.seq topologyGuard (builtins.seq (memberGuard member) bases.${member})
    );
  mkRustDerivation = args: let
    context =
      {inherit pkgs src toolchain;}
      // args
      // (
        if buildAttrs == {} && !(args ? buildAttrs)
        then {}
        else {buildAttrs = buildAttrs // (args.buildAttrs or {});}
      );
    callBases = contextualBases context (pkgHelper.consumerContext context).compileAttrs;
    automatic = baseMode == "member" && !(args ? base) && (args.useWorkspaceDeps or true) != false;
    member = context.projectDir or null;
    declaredDeps = builtins.filter (dir: dir != member) topology.plan.closureDirs.${member};
    requestedDeps = context.deps or [];
    depsGuard =
      if !builtins.isList requestedDeps || !builtins.all (dir: builtins.isString dir && builtins.elem dir declaredDeps) requestedDeps
      then fail "member mode deps must be canonical directories within the declared closure"
      else true;
    selected =
      if !automatic
      then context
      else
        builtins.seq topologyGuard (builtins.seq (memberGuard member) (builtins.seq depsGuard (context
          // {
            deps = declaredDeps;
            base = callBases.${member};
          })));
  in
    builtins.seq modeGuard (
      if args ? baseMode
      then fail "baseMode belongs to the composition factory, not member build arguments"
      else pkgHelper.mkRustDerivation selected
    );
in
  builtins.seq modeGuard {
    inherit baseFor mkRustDerivation;
    # Planning stays lazy for omitted/union and explicit escape branches.
    # Context equivalence is checked by actual helper producer reconstruction,
    # never structural equality of recursive package sets or provider labels.
    diagnostics = {
      requestedMode = baseMode;
      kind = "declared-source-closures";
      topology = topology;
      parents = builtins.seq topologyGuard (builtins.mapAttrs (member: _: parentFor member) topology.plan.closureDirs);
    };
  }

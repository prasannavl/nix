# Explicit, inert actual-constructor archive replay interface. No realizations.
{
  pkgs,
  src,
}: let
  q = import ./default.nix {inherit pkgs src;};
  consumer = q.consumers.member;
  # Forcing the real consumer forces helper reconstruction/admission of its base.
  seed = consumer.passthru.depsBase;
  operationTools = consumer.passthru.actualOperationTools;
  privateTools = pkgs.symlinkJoin {
    name = "rust-g4-freshness-private-tools";
    paths = [
      operationTools.cargo
      operationTools.rustc
      pkgs.stdenv.cc
      pkgs.coreutils
      pkgs.binutils
      pkgs.gnutar
      pkgs.zstd
      pkgs.bash
    ];
  };
  identity = drv: {
    derivationPath = drv.drvPath;
    output = drv.outputName;
    storePath = drv.outPath;
  };
  # Preserve contextual derivation recipes, not just hand-selected commands.
  normalize = value:
    if pkgs.lib.isDerivation value
    then identity value
    else if builtins.isPath value
    then toString value
    else if builtins.isList value
    then map normalize value
    else if builtins.isAttrs value
    then builtins.mapAttrs (_: normalize) value
    else if builtins.isFunction value
    then throw "freshness: function in recipe"
    else value;
  recipe = drv: normalize (builtins.removeAttrs drv.drvAttrs ["passthru" "meta"]);
  chain = base: let
    parent = base.passthru.rustClosureBaseParent or null;
  in
    (
      if parent == null
      then []
      else chain parent
    )
    ++ [
      {
        handle = identity base;
        archive = "${base}/target.tar.zst";
        recipe = base.passthru.rustClosureBaseRecipe;
        contextualRecipe = recipe base;
      }
    ];
  anchors = base: let
    parent = base.passthru.rustClosureBaseParent or null;
  in
    (
      if parent == null
      then {}
      else anchors parent
    )
    // {
      "${builtins.unsafeDiscardStringContext base.drvPath}" = {
        handle = identity base;
        contextualRecipe = recipe base;
      };
    };
  archives = chain seed;
  restorationHook = pkgs.craneLib.inheritCargoArtifactsHook;
  manifest = {
    schemaVersion = 1;
    source = toString src;
    seed = {
      handle = identity seed;
      archive = "${seed}/target.tar.zst";
      admission = {
        kind = "actual-constructor-reconstruction";
        consumer = identity consumer;
        cargoArtifacts = identity consumer.passthru.memberLayer.cargoArtifacts;
      };
      recipe = seed.passthru.rustClosureBaseRecipe;
    };
    tools = {
      cargo = "${operationTools.cargo}/bin/cargo";
      rustc = "${operationTools.rustc}/bin/rustc";
      tar = "${pkgs.gnutar}/bin/tar";
      zstd = "${pkgs.zstd}/bin/zstd";
      privateTools = identity privateTools;
      identities = builtins.mapAttrs (_: identity) operationTools;
    };
    recipeAnchors =
      anchors seed
      // {
        "${builtins.unsafeDiscardStringContext restorationHook.drvPath}" = {
          handle = identity restorationHook;
          contextualRecipe = recipe restorationHook;
        };
      };
    environment =
      consumer.passthru.__rustOperationContext.env
      // {
        PATH = "${privateTools}/bin";
        RUSTC = "${operationTools.rustc}/bin/rustc";
        CC = "${pkgs.stdenv.cc}/bin/cc";
      };
    recipes = {
      seed = recipe seed;
      consumer = recipe consumer;
      memberLayer = recipe consumer.passthru.memberLayer;
      test = recipe consumer.passthru.checks.test;
      privateTools = recipe privateTools;
    };
    restoration = {
      kind = "tar-zstd-chain-v1";
      chain = archives;
      hook = identity restorationHook;
      hookRecipe = recipe restorationHook;
      hookSemantics = "Crane inheritCargoArtifacts: recurse .prev first; zstd -d --stdout | tar -x -C target";
    };
    limits = {
      exactProducer = "not_proven";
      instrumentation = "additive --message-format=json is not recipe identity equivalence";
      priming = "restored priming not asserted fresh";
    };
  };
in
  builtins.seq consumer.drvPath {
    buildTargets = {inherit seed privateTools;};
    manifest = manifest;
  }

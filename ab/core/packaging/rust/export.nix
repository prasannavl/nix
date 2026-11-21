# Call the original definition through coherent constructor context; never fork
# recipes or consult a repository package registry. Scope is independently read.
{
  src,
  memberDirs,
  packageFile,
  scopeRust ? null,
}: let
  abCore = import ../..;
  defaultScopeRust = (import ../pkg-helper.nix {
    projectRoot = src;
  }).forRustSource {inherit src memberDirs;};
  resolveScope = pkgs:
    if scopeRust == null
    then defaultScopeRust
    else scopeRust {inherit pkgs src memberDirs;};
  matching = builtins.filter (dir: toString packageFile == "${toString src}/${dir}/default.nix") memberDirs;
  member =
    if builtins.length matching != 1
    then throw "rust-export: packageFile must be a scoped member's default.nix"
    else builtins.head matching;
  mkPackage = {
    pkgs,
    base ? null,
    ab ?
      abCore.mk {
        pkgs = pkgs;
        projectRoot = src;
      },
    packageArgs ? {},
  }: let
    scoped = resolveScope pkgs;
    mkScope = inputPkgs: let
      composition = scoped.mkRustComposition {
        pkgs = callScope;
        src = src;
        baseMode = "member";
      };
      # The selected override cannot apply to siblings with different closures.
      # All sibling defaults see automatic contextual member construction.
      contextualHelper =
        scoped
        // {
          mkRustDerivation = args:
            if base != null && (args.projectDir or null) == member
            then
              if
                args ? base
                && args.base != null
                && (!pkgs.lib.isDerivation args.base
                  || (args.base.drvPath or null) != base.drvPath
                  || (args.base.outputName or null) != base.outputName
                  || (args.base.outPath or null) != base.outPath)
              then throw "rust-export: conflicting explicit member bases"
              else
                composition.mkRustDerivation (args
                  // {
                    base = base;
                    deps =
                      builtins.filter (dir: dir != member) composition.diagnostics.topology.plan.closureDirs.${member}
                      ++ (args.deps or []);
                  })
            else composition.mkRustDerivation args;
        };
      contextualAb =
        ab
        // {
          package =
            (ab.package or {})
            // {
              withDeps = import ../with-deps.nix {inherit (callScope) callPackage;};
            };
          build =
            ab.build
            // {
              rust = contextualHelper.mkRustDerivation;
              cargoWorkspace = contextualHelper.mkCargoWorkspacePackage;
              crane = contextualHelper.mkCraneRustPackage;
              trunk = contextualHelper.mkTrunkProject;
            };
        };
      # Sibling defaults need this scope as `pkgs` as well as callPackage.
      callScope = import ../scope.nix {
        pkgs = inputPkgs;
        ab = contextualAb;
      };
    in
      callScope;
    callScope = mkScope pkgs;
    argsGuard =
      if !builtins.isAttrs packageArgs || builtins.any (key: packageArgs ? ${key}) ["pkgs" "ab" "callPackage"]
      then throw "rust-export: packageArgs cannot replace constructor context"
      else true;
    drv = callScope.callPackage packageFile packageArgs;
  in
    builtins.seq member (builtins.seq argsGuard (
      if base != null && !pkgs.lib.isDerivation base
      then throw "rust-export: base must be a derivation or null"
      else drv
    ));
in {
  inherit member mkPackage;
}

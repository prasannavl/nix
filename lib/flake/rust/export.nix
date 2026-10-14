# Call the original definition through coherent constructor context; never fork
# recipes or consult a repository package registry. Scope is independently read.
{
  src,
  memberDirs,
  packageFile,
}: let
  defaultHelper = import ../pkg-helper.nix;
  defaultStack = import ../stack/package.nix;
  matching = builtins.filter (dir: toString packageFile == "${toString src}/${dir}/default.nix") memberDirs;
  member =
    if builtins.length matching != 1
    then throw "rust-export: packageFile must be a scoped member's default.nix"
    else builtins.head matching;
  mkPackage = {
    pkgs,
    base ? null,
    pkgHelper ? defaultHelper,
    stack ? defaultStack,
    packageArgs ? {},
  }: let
    scoped = pkgHelper.forRustSource {inherit src memberDirs;};
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
                # Composition supplies the same bound src/default context as
                # automatic construction. Explicit bases skip its automatic
                # source-dependency fill: retain that closure even when an
                # intrinsic dependency is null, without dropping requested deps.
                composition.mkRustDerivation (args
                  // {
                    base = base;
                    deps =
                      builtins.filter (dir: dir != member) composition.diagnostics.topology.plan.closureDirs.${member}
                      ++ (args.deps or []);
                  })
            else composition.mkRustDerivation args;
        };
      contextualStack =
        stack
        // {
          pkg = contextualHelper;
          mkPkgs = mkScope;
          packageFor = {
            pkgs,
            packageFile,
          }:
            (mkScope pkgs).callPackage packageFile {};
        };
      # Sibling defaults need this scope as `pkgs` as well as callPackage.
      callScope =
        inputPkgs
        // {
          pkgs = callScope;
          stack = contextualStack;
          pkgHelper = contextualHelper;
          callPackage = inputPkgs.lib.callPackageWith callScope;
        };
    in
      callScope;
    callScope = mkScope pkgs;
    argsGuard =
      if !builtins.isAttrs packageArgs || builtins.any (key: packageArgs ? ${key}) ["pkgs" "stack" "pkgHelper" "callPackage"]
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

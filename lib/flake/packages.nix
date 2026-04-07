{pkgs}: let
  manifest = import ../../pkgs/manifest.nix {inherit pkgs;};
  inherit (manifest) packageEntries;
  buildEntry = packages: entry:
    if entry ? build
    then entry.build packages
    else pkgs.callPackage entry.path {};
  packageAttrs = builtins.listToAttrs (
    map (entry: {
      name = entry.id;
      value = buildEntry packageAttrs entry;
    })
    packageEntries
  );
  stdPackageEntries = builtins.listToAttrs (
    builtins.concatMap (
      entry:
        if entry ? stdPackage && !entry.stdPackage
        then []
        else [
          {
            name = entry.id;
            value = packageAttrs.${entry.id};
          }
        ]
    )
    packageEntries
  );
  extraStdPackages =
    builtins.foldl' (
      acc: entry:
        acc
        // (
          if entry ? extraStdPackages
          then entry.extraStdPackages packageAttrs
          else {}
        )
    ) {}
    packageEntries;
  rootAppEntries =
    builtins.concatMap (
      entry:
        (
          if entry ? rootApp && !entry.rootApp
          then []
          else [
            {
              name = entry.appName or entry.id;
              package = packageAttrs.${entry.id};
            }
          ]
        )
        ++ (
          if entry ? extraRootApps
          then entry.extraRootApps packageAttrs
          else []
        )
    )
    packageEntries;
in {
  packages = packageAttrs;
  stdPackages = stdPackageEntries // extraStdPackages;
  rootApps = builtins.listToAttrs (
    map (entry: {
      name = entry.name;
      value = entry.package;
    })
    rootAppEntries
  );
}

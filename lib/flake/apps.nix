{
  rootApps,
  lint ? null,
}: let
  mkApp = pkg: {
    type = "app";
    program = "${pkg}/bin/${pkg.meta.mainProgram}";
    inherit (pkg) meta;
  };
  baseApps = builtins.mapAttrs (_: mkApp) rootApps;
in
  baseApps
  // (
    if lint == null
    then {}
    else lint.apps
  )

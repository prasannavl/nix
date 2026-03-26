{
  packageSet,
  lint ? null,
}: let
  mkApp = pkg: {
    type = "app";
    program = "${pkg}/bin/${pkg.meta.mainProgram}";
    inherit (pkg) meta;
  };
  baseApps = {
    "hello-rust" = mkApp packageSet.hello-rust;
    nixbot = mkApp packageSet.nixbot;
    "cloudflare-apps-deploy" = mkApp packageSet.cloudflare-apps.deploy;
  };
in
  baseApps
  // (
    if lint == null
    then {}
    else lint.apps
  )

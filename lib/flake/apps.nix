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
    "hello-go" = mkApp packageSet.hello-go;
    "hello-node" = mkApp packageSet.hello-node;
    "hello-python" = mkApp packageSet.hello-python;
    "hello-rust" = mkApp packageSet.hello-rust;
    "hello-web-served" = mkApp packageSet.hello-web-served;
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

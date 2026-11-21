{accountData}:
import ../registry.nix {
  inherit accountData;
  stackName = "pvl-dev";
  env = "dev";
  secretScope = "dev";
  domain = "dev.p7log.com";
  internalDomain = "dev.pvl.internal";
}

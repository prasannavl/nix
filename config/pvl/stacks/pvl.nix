{accountData}:
import ../registry.nix {
  inherit accountData;
  stackName = "pvl";
  env = "prod";
  domain = "p7log.com";
  internalDomain = "pvl.internal";
}

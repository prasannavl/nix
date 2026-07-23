{
  defaultServiceStack = "pvl";

  serviceDeploymentHost = {endpoint, ...}: endpoint.host;

  generatedHostModules = {system, ...}:
    if system == "vm"
    then [../../../lib/profiles/all.nix]
    else [];
}

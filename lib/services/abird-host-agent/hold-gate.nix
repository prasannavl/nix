let
  holdFileName = resource: "${builtins.hashString "sha256" resource}.json";
  resourcePath = stateDirectory: directory: resource: "${stateDirectory}/${directory}/${holdFileName resource}";
in {
  holdFileName = holdFileName;
  userReadinessUnit = "abird-host-agent-holds-ready.service";

  holdPath = stateDirectory: resource:
    resourcePath stateDirectory "holds" resource;

  activationAuthorizationPath = stateDirectory: resource:
    resourcePath stateDirectory "activation-authorizations" resource;

  conditionsFor = {
    stateDirectory,
    resource,
    isHostResource ? false,
  }:
    if isHostResource
    then ["!${resourcePath stateDirectory "holds" resource}"]
    else [
      "|!${resourcePath stateDirectory "holds" resource}"
      "|${resourcePath stateDirectory "activation-authorizations" resource}"
    ];
}

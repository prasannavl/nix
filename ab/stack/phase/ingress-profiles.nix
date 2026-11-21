{
  lib,
  stack,
  phaseProjections,
  executorHostResource,
  executorResource,
  ingressForStack,
}: let
  ingressModel = import ../ingress-model.nix;
  baseIngress = ingressModel.normalize (ingressForStack stack);
  candidateServices =
    builtins.filter
    (service: builtins.hasAttr service stack.serviceRegistry.domains)
    (builtins.attrNames stack.serviceRegistry.services);
  splitService = projectedStack: ingress: service:
    ingressModel.splitByServerNames
    projectedStack.serviceRegistry.domains.${service}
    ingress;
  projectableServices =
    builtins.filter
    (service: ingressModel.hasHttpEntries (splitService stack baseIngress service).matched)
    candidateServices;
  profileCatalog = import ./route-profiles.nix {
    inherit
      executorHostResource
      executorResource
      lib
      phaseProjections
      stack
      ;
    services = projectableServices;
  };
  profiles =
    builtins.mapAttrs
    (service: catalog:
      builtins.mapAttrs
      (_profile: spec: let
        projectedStack = stack.withServiceRoles {${service} = spec.role;};
        projectedIngress = ingressModel.normalize (ingressForStack projectedStack);
      in {
        inherit projectedStack;
        ingress = (splitService projectedStack projectedIngress service).matched;
      })
      catalog.profiles)
    profileCatalog.catalogs;
  ordinaryIngress =
    builtins.foldl'
    (ingress: service: (splitService stack ingress service).rest)
    baseIngress
    projectableServices;
in {
  inherit ordinaryIngress profileCatalog profiles projectableServices;
}

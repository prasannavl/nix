{ingressProfiles}: {
  lib,
  stack,
  phaseProjections,
  executorHostResource,
  executorResource,
  ingressForStack,
  renderProfile,
  routePathFor,
  validationArgvFor,
  reloadServices,
}: let
  fail = message: throw "invalid nginx phase-projection adapter: ${message}";
  projection = ingressProfiles {
    inherit
      executorHostResource
      executorResource
      ingressForStack
      lib
      phaseProjections
      stack
      ;
  };
  renderedByService =
    builtins.mapAttrs
    (_service: profiles:
      builtins.mapAttrs
      (_profile: projected: renderProfile projected.ingress)
      profiles)
    projection.profiles;
  fileStates = builtins.listToAttrs (builtins.concatMap
    (service: let
      rendered = renderedByService.${service};
      serviceProfiles = builtins.attrNames rendered;
    in
      map
      (profile: {
        name = profile;
        value = {
          path = routePathFor service;
          content = rendered.${profile};
          acceptedPreviousSha256 = lib.unique (map
            (other: builtins.hashString "sha256" rendered.${other})
            (builtins.filter (other: other != profile) serviceProfiles));
          validationArgv = validationArgvFor service;
          reloadServices = reloadServices;
        };
      })
      serviceProfiles)
    projection.projectableServices);
  bootstrapFiles = builtins.listToAttrs (map
    (service: let
      catalog = projection.profileCatalog.catalogs.${service};
      baseline = catalog.baselineProfile;
      rendered = renderedByService.${service};
    in {
      name = service;
      value =
        if builtins.hasAttr baseline rendered
        then {
          path = routePathFor service;
          content = rendered.${baseline};
          profile = baseline;
          preserve = catalog.preserveBaseline;
        }
        else fail "baseline profile ${baseline} for ${service} is not in the static route catalog";
    })
    projection.projectableServices);
in {
  inherit bootstrapFiles fileStates;
  inherit
    (projection)
    ordinaryIngress
    profileCatalog
    profiles
    projectableServices
    ;
}

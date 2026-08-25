{
  lib,
  stack,
  phaseProjections,
  executorHostResource,
  executorResource,
  routeSetFor,
  serverNamesFor,
  renderProfile,
  routePathFor,
  validationArgvFor,
  reloadServices,
}: let
  fail = message: throw "invalid nginx phase-projection route: ${message}";
  profileNameFor = service: hostResource: "${service}@${hostResource}";
  activeEffects =
    builtins.concatMap
    (projection:
      builtins.filter
      (effect:
        effect.kind
        == "route_profile"
        && effect.scope == stack.stackName
        && effect.executor_host_resource == executorHostResource
        && effect.executor_resource == executorResource)
      projection.effects)
    phaseProjections;
  activeServices = map (effect: effect.service) activeEffects;
  activeEffectFor = service:
    lib.findFirst
    (effect: effect.service == service)
    null
    activeEffects;
  routeSet = routeSetFor stack;
  candidateServices =
    builtins.filter
    (service: builtins.hasAttr service stack.serviceRegistry.domains)
    (builtins.attrNames stack.serviceRegistry.services);
  splitService = projectedRouteSet: service:
    projectedRouteSet.projectedNginx.splitByServerNames
    (serverNamesFor projectedRouteSet.projectedRegistry service)
    projectedRouteSet.routes;
  hasRoutes = routes:
    lib.any (values: values != {}) (builtins.attrValues routes);
  projectableServices =
    builtins.filter
    (service: hasRoutes (splitService routeSet service).matched)
    candidateServices;
  roleNames = builtins.attrNames stack.serviceRegistry.roles;
  hostResourceForRole = role: "host:${stack.serviceRegistry.roles.${role}.host}";
  roleHostResources = map hostResourceForRole roleNames;
  renderFor = service: role: let
    projectedStack = stack.withServiceRoles {${service} = role;};
    projectedRouteSet = routeSetFor projectedStack;
  in
    renderProfile projectedRouteSet (splitService projectedRouteSet service).matched;
  renderedByService = builtins.listToAttrs (map
    (service: {
      name = service;
      value = builtins.listToAttrs (map
        (role: {
          name = profileNameFor service (hostResourceForRole role);
          value = renderFor service role;
        })
        roleNames);
    })
    projectableServices);
  baselineProfileFor = service: let
    effect = activeEffectFor service;
    canonicalRole = (stack.serviceRegistry.serviceFor service).role;
  in
    if effect == null
    then profileNameFor service (hostResourceForRole canonicalRole)
    else effect.baseline_profile;
  ordinaryRoutes =
    builtins.foldl'
    (routes: service:
      (routeSet.projectedNginx.splitByServerNames
        (serverNamesFor routeSet.projectedRegistry service)
        routes)
      .rest)
    routeSet.routes
    projectableServices;
  profileNames =
    builtins.concatMap
    (service: builtins.attrNames renderedByService.${service})
    projectableServices;
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
    projectableServices);
  bootstrapFiles = builtins.listToAttrs (map
    (service: let
      baseline = baselineProfileFor service;
      rendered = renderedByService.${service};
    in {
      name = service;
      value =
        if builtins.hasAttr baseline rendered
        then {
          path = routePathFor service;
          content = rendered.${baseline};
          profile = baseline;
          preserve = activeEffectFor service != null;
        }
        else fail "baseline profile ${baseline} for ${service} is not in the static route catalog";
    })
    projectableServices);
  activeProfilesAreDeclared =
    lib.all
    (effect: let
      declaredProfiles = map (profile: profile.profile) effect.profiles;
    in
      builtins.hasAttr effect.service renderedByService
      && builtins.elem effect.profile declaredProfiles
      && builtins.elem effect.baseline_profile declaredProfiles
      && lib.all
      (profile:
        profile.profile
        == profileNameFor effect.service profile.endpoint_host_resource
        && builtins.hasAttr profile.profile renderedByService.${effect.service})
      effect.profiles)
    activeEffects;
in
  assert lib.length activeServices == lib.length (lib.unique activeServices) || fail "services must have one active route effect";
  assert lib.length roleHostResources == lib.length (lib.unique roleHostResources) || fail "role hosts must be unique because route profiles are host-addressed";
  assert lib.all (service: builtins.match "[A-Za-z0-9_.-]+" service != null) projectableServices || fail "service names must be safe route-file components";
  assert lib.length profileNames == lib.length (lib.unique profileNames) || fail "catalog profile names must be globally unique";
  assert activeProfilesAreDeclared || fail "active route effects must select exact static catalog profiles"; {
    inherit bootstrapFiles fileStates ordinaryRoutes projectableServices;
  }

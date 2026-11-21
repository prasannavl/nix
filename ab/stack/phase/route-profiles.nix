{
  lib,
  stack,
  phaseProjections,
  executorHostResource,
  executorResource,
  services,
}: let
  validation = (import ../../core).validation;
  inherit (validation.mk "invalid phase route profile") fail;
  profileNameFor = service: hostResource: "${service}@${hostResource}";
  activeEffects =
    builtins.concatMap
    (projection:
      builtins.filter
      (effect:
        effect.kind
        == "route_profile"
        && effect.scope == stack.name
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
  roleNames = builtins.attrNames stack.serviceRegistry.roles;
  hostResourceForRole = role: "host:${stack.serviceRegistry.roles.${role}.host}";
  roleHostResources = map hostResourceForRole roleNames;
  profileFor = service: role: let
    hostResource = hostResourceForRole role;
  in {
    profile = profileNameFor service hostResource;
    inherit role hostResource;
    host = stack.serviceRegistry.roles.${role}.host;
  };
  serviceCatalogFor = service: let
    profiles = builtins.listToAttrs (map
      (role: let
        spec = profileFor service role;
      in {
        name = spec.profile;
        value = spec;
      })
      roleNames);
    effect = activeEffectFor service;
    canonicalRole = (stack.serviceRegistry.serviceFor service).role;
    canonicalProfile = (profileFor service canonicalRole).profile;
    baselineProfile =
      if effect == null
      then canonicalProfile
      else effect.baseline_profile;
    selectedProfile =
      if effect == null
      then canonicalProfile
      else effect.profile;
  in {
    inherit baselineProfile canonicalProfile profiles selectedProfile;
    preserveBaseline = effect != null;
  };
  catalogs = builtins.listToAttrs (map
    (service: {
      name = service;
      value = serviceCatalogFor service;
    })
    services);
  profileNames =
    builtins.concatMap
    (service: builtins.attrNames catalogs.${service}.profiles)
    services;
  activeProfilesAreDeclared =
    lib.all
    (effect: let
      declaredProfiles = map (profile: profile.profile) effect.profiles;
    in
      builtins.hasAttr effect.service catalogs
      && builtins.elem effect.profile declaredProfiles
      && builtins.elem effect.baseline_profile declaredProfiles
      && lib.all
      (profile:
        profile.profile
        == profileNameFor effect.service profile.endpoint_host_resource
        && builtins.hasAttr profile.profile catalogs.${effect.service}.profiles)
      effect.profiles)
    activeEffects;
in
  assert lib.length activeServices == lib.length (lib.unique activeServices) || fail "services must have one active route effect";
  assert lib.length roleHostResources == lib.length (lib.unique roleHostResources) || fail "role hosts must be unique because route profiles are host-addressed";
  assert lib.all (service: builtins.match "[A-Za-z0-9_.-]+" service != null) services || fail "service names must be safe route-profile components";
  assert lib.length profileNames == lib.length (lib.unique profileNames) || fail "catalog profile names must be globally unique";
  assert activeProfilesAreDeclared || fail "active route effects must select exact static catalog profiles"; {
    inherit activeEffects catalogs;
  }

{
  pkgs,
  registry,
}: let
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  roles = {
    a.name = "a";
    b.name = "b";
  };
  duplicateServices = registry.normalizeServices roles {
    a.web = {};
    b.web = {};
  };
  overriddenServices = registry.normalizeServices roles (registry.mergeRoleServices
    {a.web.port = 80;}
    {a.web.port = 8080;});
  rawFor = role: {
    name = "fixture";
    network.externalConnectors = false;
    topology.existing = "preserved";
    infra.existing = "preserved";
    serviceRegistry = {role = role;};
    withServiceRoles = overrides: rawFor overrides.web;
  };
  raw = rawFor "a";
  projection = {
    network.fabric = "test";
    topology.instances.web.address = "10.0.0.2";
    infra.incus.stateVolumeSize = "8G";
    extension.marker = "preserved";
  };
  placements.cold.name = "cold";
  assemble = stack:
    registry.finalizeStack {
      inherit stack projection placements;
      withServiceRoles = overrides: assemble (stack.withServiceRoles overrides);
    };
  assembled = assemble raw;
  remapped = assembled.withServiceRoles {web = "b";};
  leaf = registry.finalizeStack {
    stack = raw;
    projection = projection;
  };
  invalid = projection:
    registry.finalizeStack {
      stack = raw;
      projection = projection;
    };
in
  assert rejects duplicateServices;
  assert overriddenServices.web.port == 8080;
  assert overriddenServices.web.role == "a";
  assert assembled.network
  == {
    externalConnectors = false;
    fabric = "test";
  };
  assert assembled.topology.existing == "preserved";
  assert assembled.topology.instances.web.address == "10.0.0.2";
  assert assembled.topology.placements == placements;
  assert !(leaf.topology ? placements);
  assert assembled.infra.existing == "preserved";
  assert assembled.infra.incus.stateVolumeSize == "8G";
  assert assembled.extension.marker == "preserved";
  assert remapped.serviceRegistry.role == "b";
  assert remapped.network == assembled.network;
  assert remapped.topology == assembled.topology;
  assert (remapped.withServiceRoles {web = "a";}).serviceRegistry.role == "a";
  assert rejects (invalid {name = "shadowed";});
  assert rejects (invalid {network.externalConnectors = true;});
  assert rejects (invalid {topology.placements = {};});
  assert rejects (invalid {withServiceRoles = _: {};});
    pkgs.runCommand "ab-stack-assembly-test" {} ''
      touch "$out"
    ''

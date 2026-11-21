{core}:
assert core.name == "ab-core"; let
  validation = core.validation;
  accounts = import ./accounts;
  access = import ./fabric/access.nix {inherit validation;};
  mkFabricContract = args:
    import ./fabric/contract.nix ({accessSelectors = access;} // args);
  mkFabric = args:
    import ./fabric/mk.nix ({
        accessSelectors = access;
        mkContract = mkFabricContract;
      }
      // args);
  mkBase = import ./base.nix;
  ingressDeclarations = args:
    import ./ingress-declarations.nix ({inherit validation;} // args);
  ingress =
    import ./ingress-model.nix
    // {declarations = ingressDeclarations;};
  registry = import ./registry.nix {
    inherit mkBase validation;
    ingressDeclarations = ingress.declarations;
  };
  buildSet = args:
    import ./build-set.nix ({registryLib = registry;} // args);
  fabric = {
    inherit access;
    contract = mkFabricContract;
    incus = {lib}: import ./fabric/incus.nix {inherit lib;};
    mk = mkFabric;
    projection = import ./fabric/projection.nix {accessSelectors = access;};
  };
  config = {
    family = import ./config/config-family.nix {inherit validation mkFabric buildSet;};
    prebuiltFamily = args: import ./config/prebuilt-config-family.nix args;
  };
  phase = {
    ingressProfiles = args: import ./phase/ingress-profiles.nix args;
    projection = import ./phase/projection.nix {inherit validation serviceStack;};
    routeProfiles = args: import ./phase/route-profiles.nix args;
  };
  secrets = import ./secrets.nix;
  servicePolicy = import ./service-policy.nix;
  serviceStack = import ./service-stack.nix;
  tunnels = import ./tunnels;
  units = import ./units.nix;

  mk = {definition}:
    assert builtins.isAttrs definition;
    assert definition ? name;
      definition
      // {
        ingress = ingress.normalize (definition.ingress or {});
      };
in {
  name = "ab-stack";
  dependencies = {
    required = ["core"];
    optional = [];
  };

  inherit accounts buildSet config fabric ingress mk mkBase phase registry secrets servicePolicy serviceStack tunnels units;
}

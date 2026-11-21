{
  factProjection,
  tunnels,
}: {
  config,
  lib,
  ...
}: let
  cfg = config.services.podman-compose;
  facts = config._ab.runtime.podman.facts;

  stackProjection = stackName: stack: let
    instances = factProjection.projectedInstances {
      inherit facts stack;
    };
    endpoints = tunnels.endpointsFromInstances stackName instances;
  in {
    inherit endpoints;
    ingress = lib.genAttrs tunnels.kinds (
      kind: tunnels.ingressFromEndpoints kind endpoints
    );
  };

  projections = lib.mapAttrs stackProjection cfg;
in {
  options.services.podman-compose-tunnel-projection = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        ingress = lib.mkOption {
          type = lib.types.attrs;
          readOnly = true;
        };
        endpoints = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          readOnly = true;
        };
      };
    });
    default = projections;
    readOnly = true;
    internal = true;
    description = "Tunnel projection derived from Podman declaration policy and neutral runtime facts.";
  };
}

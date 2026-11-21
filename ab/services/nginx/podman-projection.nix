{
  factProjection,
  nginx,
}: {
  config,
  lib,
  ...
}: let
  cfg = config.services.podman-compose;
  facts = config._ab.runtime.podman.facts;

  stackProjection = _stackName: stack: let
    instances = factProjection.projectedInstances {
      inherit facts stack;
    };
  in {
    proxyVhosts =
      nginx.proxyVhostsFromInstances {
        defaultHost = stack.nginxDefaultHost;
      }
      instances;
    routes =
      nginx.routesFromInstances {
        defaultHost = stack.nginxDefaultHost;
      }
      instances;
  };

  projections = lib.mapAttrs stackProjection cfg;
in {
  options.services.podman-compose-nginx-projection = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        proxyVhosts = lib.mkOption {
          type = lib.types.attrs;
          readOnly = true;
        };
        routes = lib.mkOption {
          type = lib.types.attrs;
          readOnly = true;
        };
      };
    });
    default = projections;
    readOnly = true;
    internal = true;
    description = "Nginx service projection derived from Podman declaration policy and neutral runtime facts.";
  };
}

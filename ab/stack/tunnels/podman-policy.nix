{
  lib,
  kinds,
}: {
  portOptions.tunnels = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        kind = lib.mkOption {
          type = lib.types.enum kinds;
          description = "Tunnel transport kind that should publish this exposed port.";
        };

        hostNames = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          description = "Public hostnames or stable endpoint names published through this tunnel transport.";
        };

        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional stable logical tunnel endpoint name. Defaults to the first hostName.";
        };

        targetPort = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "Optional host port this tunnel should target. Defaults to this exposed port.";
        };

        service = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional rendered tunnel service target. Defaults to a protocol-derived localhost target.";
        };

        remotePort = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "Optional public bind port for tunnel kinds, such as rathole, that expose numbered remote ports instead of hostname ingress.";
        };
      };
    });
    default = [];
    description = "Provider-neutral tunnel publications for this exposed port.";
  };
}

{lib}: {
  portOptions = {
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this runtime port should be included when deriving host firewall rules.";
    };

    upstreamProtocol = lib.mkOption {
      type = lib.types.enum ["http" "https" "tcp" "udp"];
      default = "http";
      description = "Protocol exposed by this runtime port and used by readiness/projection consumers.";
    };

    upstreamHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional logical upstream host used by HTTP readiness and higher-level projections.";
    };

    upstreamTlsName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "auto";
      description = "TLS SNI name for HTTPS readiness/projection consumers. auto derives it from upstreamHost; null disables SNI.";
    };
  };

  httpProbeForPort = port: {
    protocol = port.upstreamProtocol;
    host = port.upstreamHost;
    tlsName =
      if port.upstreamTlsName == "auto"
      then port.upstreamHost
      else port.upstreamTlsName;
  };
}

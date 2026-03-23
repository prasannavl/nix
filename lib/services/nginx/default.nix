{lib}: let
  proxyVhostType = lib.types.submodule (_: {
    options = {
      service = lib.mkOption {
        type = lib.types.str;
        description = "Compose service name nginx should depend on for this vhost.";
      };

      serverNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Hostname(s) served by this nginx proxy vhost.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "Local backend port nginx should forward to.";
      };
    };
  });

  mkProxyVhost = serviceName: portName: portCfg: let
    nginxHostNames = portCfg.nginxHostNames or [];
  in
    lib.optionalAttrs (nginxHostNames != []) {
      "${serviceName}-${portName}" = {
        service = serviceName;
        inherit (portCfg) port;
        serverNames = nginxHostNames;
      };
    };

  mkProxyServer = name: proxy: ''
    # ${name}
    server {
        listen 80;
        server_name ${lib.concatStringsSep " " proxy.serverNames};

        include /etc/nginx/conf.d/lib/http-security.conf;

        location / {
            proxy_pass http://127.0.0.1:${toString proxy.port};
        }
    }
  '';
in {
  inherit proxyVhostType;

  composeSource = ./compose/compose.yaml;

  baseFiles = {
    "nginx.conf" = ./compose/nginx.conf;
    "conf.d" = ./compose/conf.d;
  };

  proxyVhostsFromInstances = instances:
    lib.concatMapAttrs
    (serviceName: service:
      lib.concatMapAttrs
      (portName: portCfg: mkProxyVhost serviceName portName portCfg)
      service.exposedPorts)
    instances;

  dependencyServices = proxyVhosts:
    lib.unique (map (proxy: proxy.service) (builtins.attrValues proxyVhosts));

  renderProxyServers = proxyVhosts:
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkProxyServer proxyVhosts);
}

{lib}: let
  proxyVhostType = lib.types.submodule {
    options = {
      service = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
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

      upstreams = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Backend server addresses (host:port).";
      };
    };
  };

  mkProxyVhost = {defaultHost ? "localhost"}: serviceName: portName: portCfg: let
    nginxHostNames = portCfg.nginxHostNames or [];
  in
    lib.optionalAttrs (nginxHostNames != []) {
      "${serviceName}-${portName}" = {
        service = serviceName;
        inherit (portCfg) port;
        serverNames = nginxHostNames;
        upstreams = ["${defaultHost}:${toString portCfg.port}"];
      };
    };

  mkUpstreamBlock = name: upstreams: ''
    upstream ${name} {
        ${lib.concatMapStringsSep "\n        " (s: "server ${s};") upstreams}
    }
  '';

  mkProxyServer = name: proxy: ''
    ${mkUpstreamBlock name proxy.upstreams}
    # ${name}
    server {
        listen 80;
        server_name ${lib.concatStringsSep " " proxy.serverNames};

        include /etc/nginx/conf.d/lib/http-security.conf;

        location / {
            proxy_pass http://${name};
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

  proxyVhostsFromInstances = {defaultHost ? "localhost"}: instances:
    lib.concatMapAttrs
    (serviceName: service:
      lib.concatMapAttrs
      (portName: portCfg: mkProxyVhost {inherit defaultHost;} serviceName portName portCfg)
      service.exposedPorts)
    instances;

  dependencyServices = proxyVhosts:
    lib.unique (lib.filter (s: s != null) (map (proxy: proxy.service) (builtins.attrValues proxyVhosts)));

  renderProxyServers = proxyVhosts:
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkProxyServer proxyVhosts);
}

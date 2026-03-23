{lib}: let
  proxyVhostType = lib.types.submodule ({name, ...}: {
    options = {
      service = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Compose service name nginx should depend on for this vhost.";
      };

      serverNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Hostname(s) served by this nginx proxy vhost.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "Local backend port nginx and Cloudflare tunnel should forward to.";
      };
    };
  });

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
  proxyVhostsOption = lib.mkOption {
    type = lib.types.attrsOf proxyVhostType;
    default = {};
    description = "Shared reverse-proxy vhost declarations used by nginx and tunnel ingress.";
  };

  composeSource = ./compose/compose.yaml;

  baseFiles = {
    "nginx.conf" = ./compose/nginx.conf;
    "conf.d" = ./compose/conf.d;
  };

  dependencyServices = proxyVhosts:
    lib.unique (map (proxy: proxy.service) (builtins.attrValues proxyVhosts));

  renderProxyServers = proxyVhosts:
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkProxyServer proxyVhosts);
}

{
  config,
  lib,
  ...
}: let
  nginxLib = import ../../../lib/services/nginx {inherit lib;};
  proxyVhosts = config.services.podman-compose.pvl.nginx-proxy-vhosts;
  nginxRoutes = config.services.podman-compose.pvl.nginxRoutes;
  backendServices = nginxLib.dependencyServices (proxyVhosts // nginxRoutes);
  nginxLogDir = "/var/log/pvl/nginx";
in {
  config = {
    services = {
      podman-compose.pvl.instances.nginx = rec {
        reload = {
          method = "signal";
          signal = "HUP";
          services = ["nginx"];
          trigger.dirs = ["conf.d"];
        };

        exposedPorts.http = {
          port = 10800;
          openFirewall = true;
        };
        wants = backendServices;

        source = nginxLib.composeSource;
        files =
          nginxLib.baseFiles
          // {
            ".env".text = ''
              NGINX_HTTP_PORT=${toString exposedPorts.http.port}
              NGINX_LOG_DIR=${nginxLogDir}
            '';
            "conf.d/srv-http-default.conf".text = nginxLib.renderServers {
              nginxRoutes = nginxRoutes;
              proxyVhosts = proxyVhosts;
            };
          };
      };

      fail2ban-helper.nginx = {
        enable = true;
        logPaths = lib.mkAfter ["${nginxLogDir}/error.log"];
      };
      fail2ban.enable = true;
      fail2ban-helper.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d ${nginxLogDir} 0755 pvl pvl -"
      "f ${nginxLogDir}/access.log 0644 pvl pvl -"
      "f ${nginxLogDir}/error.log 0644 pvl pvl -"
    ];
  };
}

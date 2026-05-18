{
  config,
  lib,
  ...
}: let
  nginxLib = import ../../../lib/services/nginx {inherit lib;};
  proxyVhosts = config.services.podmanCompose.pvl.nginxProxyVhosts;
  nginxRoutes = config.services.podmanCompose.pvl.nginxRoutes;
  backendServices = nginxLib.dependencyServices (proxyVhosts // nginxRoutes);
in {
  config.services.podmanCompose.pvl.instances.nginx = rec {
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
        '';
        "conf.d/srv-http-default.conf".text = nginxLib.renderServers {
          nginxRoutes = nginxRoutes;
          proxyVhosts = proxyVhosts;
        };
      };
  };
}

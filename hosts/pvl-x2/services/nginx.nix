{
  config,
  lib,
  ...
}: let
  nginxLib = import ../../../lib/services/nginx {inherit lib;};
  proxyVhosts = config.services.podmanCompose.pvl.nginxProxyVhosts;
in {
  config.services.podmanCompose.pvl.instances.nginx = rec {
    exposedPorts.http = {
      port = 10800;
      openFirewall = true;
    };
    wants = nginxLib.dependencyServices proxyVhosts;

    source = nginxLib.composeSource;
    files =
      nginxLib.baseFiles
      // {
        ".env".text = ''
          NGINX_HTTP_PORT=${toString exposedPorts.http.port}
        '';
        "conf.d/srv-http-default.conf".text = nginxLib.renderProxyServers proxyVhosts;
      };
  };
}

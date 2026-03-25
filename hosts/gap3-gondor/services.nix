{...}: {
  systemd.tmpfiles.rules = [
    "d /var/lib/gap3 0755 gap3 gap3 -"
    "d /var/lib/gap3/compose 0750 gap3 gap3 -"
    "d /var/lib/gap3/compose/nginx 0750 gap3 gap3 -"
    "d /var/lib/gap3/nginx 0750 gap3 gap3 -"
  ];

  networking.firewall.allowedTCPPorts = [
    18080
  ];

  services.podmanCompose.gap3 = {
    user = "gap3";
    stackDir = "/var/lib/gap3/compose";
    servicePrefix = "gap3-";

    instances = {
      nginx.source = ''
        services:
          nginx:
            image: docker.io/library/nginx:latest
            restart: unless-stopped
            ports:
              - "0.0.0.0:18080:80"
            volumes:
              - /var/lib/gap3/nginx:/usr/share/nginx/html:Z
      '';
    };
  };
}

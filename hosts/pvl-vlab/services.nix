{config, ...}: let
  videoGid = toString config.users.groups.video.gid;
  renderGid = toString config.users.groups.render.gid;
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/pvl 0755 pvl pvl -"
    "d /var/lib/pvl/compose 0750 pvl pvl -"
    "d /var/lib/pvl/compose/nginx 0750 pvl pvl -"
    "d /var/lib/pvl/compose/ollama 0750 pvl pvl -"
    "d /var/lib/pvl/compose/open-webui 0750 pvl pvl -"
    "d /var/lib/pvl/nginx 0750 pvl pvl -"
    "d /var/lib/pvl/open-webui 0750 pvl pvl -"
    "d /var/lib/pvl/ollama 0750 pvl pvl -"
  ];
  networking.firewall.allowedTCPPorts = [
    18080
    21434
    13000
  ];

  services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";

    instances = {
      nginx.source = ''
        services:
          nginx:
            image: docker.io/library/nginx:latest
            restart: unless-stopped
            ports:
              - "0.0.0.0:18080:80"
            volumes:
              - /var/lib/pvl/nginx:/usr/share/nginx/html:Z
      '';

      ollama.source = ''
        services:
          ollama:
            image: docker.io/ollama/ollama:latest
            restart: unless-stopped
            environment:
              - OLLAMA_VULKAN=1
            ports:
              - "0.0.0.0:21434:11434"
            volumes:
              - /var/lib/pvl/ollama:/root/.ollama:Z
              - /dev/dri:/dev/dri
            group_add:
              - ${videoGid}
              - ${renderGid}
            devices:
              - /dev/kfd:/dev/kfd
      '';

      open-webui = {
        source = ''
          services:
            open-webui:
              image: ghcr.io/open-webui/open-webui:main
              restart: unless-stopped
              ports:
                - "0.0.0.0:13000:8080"
              environment:
                OLLAMA_BASE_URL: "http://host.containers.internal:21434"
              volumes:
                - /var/lib/pvl/open-webui:/app/backend/data:Z
        '';
        dependsOn = ["ollama"];
      };
    };
  };
}

{...}: {
  systemd.tmpfiles.rules = [
    "d /var/lib/llmug 0755 llmug llmug -"
    "d /var/lib/llmug/compose 0750 llmug llmug -"
    "d /var/lib/llmug/compose/nginx 0750 llmug llmug -"
    "d /var/lib/llmug/compose/ollama 0750 llmug llmug -"
    "d /var/lib/llmug/compose/open-webui 0750 llmug llmug -"
    "d /var/lib/llmug/nginx 0750 llmug llmug -"
    "d /var/lib/llmug/open-webui 0750 llmug llmug -"
    "d /var/lib/llmug/ollama 0750 llmug llmug -"
  ];
  networking.firewall.allowedTCPPorts = [
    18080
    21434
    13000
  ];

  services.podmanCompose.llmug = {
    user = "llmug";
    workingDir = "/var/lib/llmug/compose";
    servicePrefix = "llmug-";

    services = {
      nginx.source = ''
        services:
          nginx:
            image: docker.io/library/nginx:latest
            restart: unless-stopped
            ports:
              - "0.0.0.0:18080:80"
            volumes:
              - /var/lib/llmug/nginx:/usr/share/nginx/html:Z
      '';

      ollama.source = ''
        services:
          ollama:
            image: docker.io/ollama/ollama:latest
            restart: unless-stopped
            ports:
              - "0.0.0.0:21434:11434"
            volumes:
              - /var/lib/llmug/ollama:/root/.ollama:Z
            group_add:
              - video
              - render
            devices:
              - /dev/dri:/dev/dri
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
                - /var/lib/llmug/open-webui:/app/backend/data:Z
        '';
        dependsOn = ["ollama"];
      };
    };
  };
}

{
  ...
}: {
  systemd.tmpfiles.rules = [
    "d /srv 0755 root root -"
    "d /srv/nginx 0755 root root -"
    "d /srv/open-webui 0750 root root -"
    "d /srv/ollama 0750 root root -"
  ];

  virtualisation.oci-containers.containers = {
    nginx-container = {
      image = "docker.io/library/nginx:latest";
      autoStart = true;
      ports = ["0.0.0.0:8080:80"];
      volumes = [
        "/srv/nginx:/usr/share/nginx/html"
      ];
    };

    ollama = {
      image = "docker.io/ollama/ollama:latest";
      autoStart = true;
      ports = ["0.0.0.0:11434:11434"];
      volumes = [
        "/srv/ollama:/root/.ollama"
      ];
      extraOptions = [
        "--device=nvidia.com/gpu=all"
      ];
    };

    open-webui = {
      image = "ghcr.io/open-webui/open-webui:main";
      autoStart = true;
      ports = ["0.0.0.0:3000:8080"];
      environment = {
        OLLAMA_BASE_URL = "http://host.containers.internal:11434";
      };
      volumes = [
        "/srv/open-webui:/app/backend/data"
      ];
      dependsOn = ["ollama"];
    };
  };

  networking.firewall.allowedTCPPorts = [
    8080
    11434
    3000
  ];
}

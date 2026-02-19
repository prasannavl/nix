{
  ...
}: {
  systemd.tmpfiles.rules = [
    "d /var/lib/llmug 0755 root root -"
    "d /var/lib/llmug/nginx 0755 root root -"
    "d /var/lib/llmug/open-webui 0755 root root -"
    "d /var/lib/llmug/ollama 0755 root root -"
  ];

  virtualisation.oci-containers.containers = {
    nginx-container = {
      image = "docker.io/library/nginx:latest";
      autoStart = true;
      ports = ["0.0.0.0:8080:80"];
      volumes = [
        "/var/lib/llmug/nginx:/usr/share/nginx/html"
      ];
    };

    ollama = {
      image = "docker.io/ollama/ollama:latest";
      autoStart = true;
      ports = ["0.0.0.0:11434:11434"];
      volumes = [
        "/var/lib/llmug/ollama:/root/.ollama"
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
        "/var/lib/llmug/open-webui:/app/backend/data"
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

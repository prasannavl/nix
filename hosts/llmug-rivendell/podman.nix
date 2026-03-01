{...}: {
  systemd.tmpfiles.rules = [
    "d /var/lib/llmug 0755 llmug llmug -"
    "d /var/lib/llmug/nginx.pod 0750 llmug llmug -"
    "d /var/lib/llmug/open-webui.pod 0750 llmug llmug -"
    "d /var/lib/llmug/ollama.pod 0750 llmug llmug -"
  ];

  virtualisation.oci-containers.containers = {
    nginx-container = {
      image = "docker.io/library/nginx:latest";
      autoStart = true;
      podman.user = "llmug";
      ports = ["0.0.0.0:8080:80"];
      volumes = [
        "/var/lib/llmug/nginx.pod:/usr/share/nginx/html"
      ];
    };

    ollama = {
      image = "docker.io/ollama/ollama:latest";
      autoStart = true;
      podman.user = "llmug";
      ports = ["0.0.0.0:11434:11434"];
      volumes = [
        "/var/lib/llmug/ollama.pod:/root/.ollama"
      ];
      extraOptions = [
        "--group-add=video"
        "--group-add=render"
        "--device=/dev/dri:/dev/dri"
        "--device=/dev/kfd:/dev/kfd"
      ];
    };

    open-webui = {
      image = "ghcr.io/open-webui/open-webui:main";
      autoStart = true;
      podman.user = "llmug";
      ports = ["0.0.0.0:3000:8080"];
      environment = {
        OLLAMA_BASE_URL = "http://host.containers.internal:11434";
      };
      volumes = [
        "/var/lib/llmug/open-webui.pod:/app/backend/data"
      ];
      dependsOn = ["ollama"];
    };
  };

  systemd.services = {
    podman-nginx-container.serviceConfig.Delegate = true;
    podman-ollama.serviceConfig.Delegate = true;
    podman-open-webui.serviceConfig.Delegate = true;
  };

  networking.firewall.allowedTCPPorts = [
    8080
    11434
    3000
  ];
}

{config, ...}: let
  videoGid = toString config.users.groups.video.gid;
  renderGid = toString config.users.groups.render.gid;
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/pvl 0755 pvl pvl -"
    "d /var/lib/pvl/nginx.pod 0750 pvl pvl -"
    "d /var/lib/pvl/open-webui.pod 0750 pvl pvl -"
    "d /var/lib/pvl/ollama.pod 0750 pvl pvl -"
  ];

  virtualisation.oci-containers.containers = {
    nginx-container = {
      image = "docker.io/library/nginx:latest";
      autoStart = true;
      podman.user = "pvl";
      ports = ["0.0.0.0:8080:80"];
      volumes = [
        "/var/lib/pvl/nginx.pod:/usr/share/nginx/html"
      ];
    };

    ollama = {
      image = "docker.io/ollama/ollama:rocm";
      autoStart = true;
      podman.user = "pvl";
      ports = ["0.0.0.0:11434:11434"];
      environment = {
        OLLAMA_VULKAN = "1";
      };
      volumes = [
        "/var/lib/pvl/ollama.pod:/root/.ollama"
        "/dev/dri:/dev/dri"
      ];
      extraOptions = [
        "--group-add=${videoGid}"
        "--group-add=${renderGid}"
        "--device=/dev/kfd:/dev/kfd"
      ];
    };

    open-webui = {
      image = "ghcr.io/open-webui/open-webui:main";
      autoStart = true;
      podman.user = "pvl";
      ports = ["0.0.0.0:3000:8080"];
      environment = {
        OLLAMA_BASE_URL = "http://host.containers.internal:11434";
      };
      volumes = [
        "/var/lib/pvl/open-webui.pod:/app/backend/data"
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

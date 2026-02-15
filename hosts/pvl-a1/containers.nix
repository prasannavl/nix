{...}: {
  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      nginx-container = {
        image = "nginx:latest";
        ports = ["8080:80"];
      };

      open-webui = {
        image = "ghcr.io/open-webui/open-webui:main";
        ports = ["3000:8080"];
        volumes = ["open-webui:/app/backend/data"];
        environment = {
          # Points to Ollama on the host
          "OLLAMA_BASE_URL" = "http://host.docker.internal:11434";
        };
        # Allows the container to talk to the host's localhost (Ollama)
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
      };

      ollama = {
        image = "ollama/ollama:latest"; # Use "ollama/ollama:rocm" for AMD
        ports = ["11434:11434"];
        volumes = ["ollama_data:/root/.ollama"];
        # For NVIDIA GPU, add:
        extraOptions = ["--gpus=all"];
      };
    };
  };

  # nixos containers
  # 
  # containers.ollama-container = {
  #   autoStart = true;
  #   # Allows the container to use the host's network (simpler for API access)
  #   privateNetwork = false;
  #   bindMounts = {
  #     # Key: path inside the container
  #     # Value: options for the mount
  #     "/var/lib/ollama" = {
  #       hostPath = "/home/pvl/data/ollama-data"; # Path on your physical host
  #       isReadOnly = false; # Set to true for read-only access
  #     };
  #   };

  #   # GPU Passthrough (Optional - see Hardware section below)
  #   # bindMounts = { "/dev/dri" = { hostPath = "/dev/dri"; isReadOnly = false; }; };

  #   config = {
  #     config,
  #     pkgs,
  #     ...
  #   }: {
  #     # Enable the native Ollama service
  #     services.ollama = {
  #       enable = true;
  #       # Choose: "cuda" for NVIDIA, "rocm" for AMD, or null for CPU-only
  #       acceleration = null;
  #       # Optional: Preload models on startup
  #       # loadModels = [ "llama3.2" ];
  #     };

  #     # Open the firewall inside the container if using privateNetwork = true
  #     networking.firewall.allowedTCPPorts = [11434];

  #     system.stateVersion = "25.11"; # Match your host version
  #   };
  # };
}

{config, ...}: let
  ai = config.services.ai;
in {
  # Container definition only: image, devices, and tuning. Model pulls and
  # lifecycle are owned by services.ai.
  services.podman-compose.pvl.instances.ollama = rec {
    exposedPorts.main = {
      port = ai.backends.ollama.portsByName.ollama;
      openFirewall = true;
    };

    source = ''
      services:
        ollama:
          image: docker.io/ollama/ollama:0.34.0-rocm
          container_name: ollama
          ports:
            - "${toString exposedPorts.main.port}:11434"
          volumes:
            - ./ollama_data:/root/.ollama
          environment:
            - OLLAMA_VULKAN=1
            - AMD_VISIBLE_DEVICES=0
            - OLLAMA_FLASH_ATTENTION=1
            - OLLAMA_KV_CACHE_TYPE=q8_0
            - OLLAMA_KEEP_ALIVE=12h
            - ROCR_VISIBLE_DEVICES=0
            - OLLAMA_CONTEXT_LENGTH=262144
          devices:
            - "/dev/kfd:/dev/kfd"
            - "/dev/dri:/dev/dri"
          group_add:
            - keep-groups
    '';

    # Model pulls run in pvl-ollama-models-pull; this covers cold image/container startup.
    serviceOverrides.serviceConfig.TimeoutStartSec = "5min";
  };
}

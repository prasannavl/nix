{lib, ...}: let
  ollamaInstances = {
    ollama = {
      port = 21434;
      dataDir = "/var/lib/gap3/ollama";
    };
    ollama-b = {
      port = 21435;
      dataDir = "/var/lib/gap3/ollama-b";
    };
    ollama-c = {
      port = 21436;
      dataDir = "/var/lib/gap3/ollama-c";
    };
  };

  mkOllamaInstance = name: instance: {
    source = ''
      services:
        ${name}:
          image: docker.io/ollama/ollama:latest
          restart: unless-stopped
          environment:
            - OLLAMA_VULKAN=1
          ports:
            - "0.0.0.0:${toString instance.port}:11434"
          volumes:
            - ${instance.dataDir}:/root/.ollama:Z
            - /dev/dri:/dev/dri
          group_add:
            - video
            - render
          devices:
            - /dev/kfd:/dev/kfd
    '';
    serviceOverrides.serviceConfig.Delegate = true;
  };

  ollamaPorts = lib.mapAttrsToList (_: instance: instance.port) ollamaInstances;
  ollamaTmpfiles = lib.concatLists (
    lib.mapAttrsToList (
      name: instance: [
        "d /var/lib/gap3/compose/${name} 0750 gap3 gap3 -"
        "d ${instance.dataDir} 0750 gap3 gap3 -"
      ]
    )
    ollamaInstances
  );
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/gap3 0755 gap3 gap3 -"
    "d /var/lib/gap3/compose 0750 gap3 gap3 -"
    "d /var/lib/gap3/compose/open-webui 0750 gap3 gap3 -"
    "d /var/lib/gap3/open-webui 0750 gap3 gap3 -"
  ] ++ ollamaTmpfiles;

  networking.firewall.allowedTCPPorts = ollamaPorts ++ [13000];

  services.podmanCompose.gap3 = {
    user = "gap3";
    stackDir = "/var/lib/gap3/compose";
    servicePrefix = "gap3-";

    instances =
      lib.mapAttrs mkOllamaInstance ollamaInstances
      // {
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
                  - /var/lib/gap3/open-webui:/app/backend/data:Z
          '';
          dependsOn = ["ollama"];
          serviceOverrides.serviceConfig.Delegate = true;
        };
      };
  };
}

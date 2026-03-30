{
  config,
  lib,
  ...
}: let
  videoGid = toString config.users.groups.video.gid;
  renderGid = toString config.users.groups.render.gid;
  recreateTag = "1";

  ollamaInstances = {
    ollama = {
      port = 21434;
      dataDir = "/var/lib/pvl/ollama";
    };
    ollama-b = {
      port = 21435;
      dataDir = "/var/lib/pvl/ollama-b";
    };
    ollama-c = {
      port = 21436;
      dataDir = "/var/lib/pvl/ollama-c";
    };
  };

  mkOllamaInstance = name: instance: {
    recreateTag = recreateTag;
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
            - ${videoGid}
            - ${renderGid}
          devices:
            - /dev/kfd:/dev/kfd
    '';
  };

  ollamaPorts = lib.mapAttrsToList (_: instance: instance.port) ollamaInstances;
  ollamaTmpfiles = lib.concatLists (
    lib.mapAttrsToList (
      name: instance: [
        "d /var/lib/pvl/compose/${name} 0750 pvl pvl -"
        "d ${instance.dataDir} 0750 pvl pvl -"
      ]
    )
    ollamaInstances
  );
in {
  networking.firewall.trustedInterfaces = ["incusbr0"];

  systemd.tmpfiles.rules =
    [
      "d /var/lib/pvl 0755 pvl pvl -"
      "d /var/lib/pvl/compose 0750 pvl pvl -"
      "d /var/lib/pvl/compose/open-webui 0750 pvl pvl -"
      "d /var/lib/pvl/open-webui 0750 pvl pvl -"
    ]
    ++ ollamaTmpfiles;

  networking.firewall.allowedTCPPorts = ollamaPorts ++ [13000];

  services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";

    instances =
      lib.mapAttrs mkOllamaInstance ollamaInstances
      // {
        open-webui = {
          recreateTag = recreateTag;
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

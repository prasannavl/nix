{pkgs, ...}: let
  mkComposeService = {
    name,
    composeFile ? null,
    composeDir ? null,
    sourceFile,
  }: let
    resolvedComposeDir =
      if composeDir != null
      then composeDir
      else if composeFile != null
      then builtins.dirOf composeFile
      else "/var/lib/llmug/compose/${name}";
    resolvedComposeFile =
      if composeFile != null
      then composeFile
      else "${resolvedComposeDir}/compose.yml";
    podmanCompose = "${pkgs.podman}/bin/podman compose -f ${resolvedComposeFile}";
  in {
    unitConfig.ConditionUser = "llmug";
    description = "podman llmug service: ${name}";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["default.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Rootless Podman needs newuidmap/newgidmap NixOS wrappers.
      Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
      WorkingDirectory = resolvedComposeDir;
      ExecStartPre = "${pkgs.coreutils}/bin/install -m 0640 ${sourceFile} ${resolvedComposeFile}";
      ExecStart = "${podmanCompose} up -d --remove-orphans";
      ExecStop = "${podmanCompose} down";
      ExecReload = "${podmanCompose} up -d --remove-orphans";
      TimeoutStartSec = 900;
      TimeoutStopSec = 300;
    };
  };
in {
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

  environment.etc."llmug/compose/nginx.yml".text = ''
    services:
      nginx:
        image: docker.io/library/nginx:latest
        restart: unless-stopped
        ports:
          - "0.0.0.0:18080:80"
        volumes:
          - /var/lib/llmug/nginx:/usr/share/nginx/html:Z
  '';

  environment.etc."llmug/compose/ollama.yml".text = ''
    services:
      ollama:
        image: docker.io/ollama/ollama:latest
        restart: unless-stopped
        ports:
          - "0.0.0.0:21434:11434"
        volumes:
          - /var/lib/llmug/ollama:/root/.ollama:Z
        devices:
          - nvidia.com/gpu=all
  '';

  environment.etc."llmug/compose/open-webui.yml".text = ''
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

  systemd.user.services = {
    llmug-nginx = mkComposeService {
      name = "nginx";
      sourceFile = "/etc/llmug/compose/nginx.yml";
    };
    llmug-ollama = mkComposeService {
      name = "ollama";
      sourceFile = "/etc/llmug/compose/ollama.yml";
    };
    llmug-open-webui =
      (mkComposeService {
        name = "open-webui";
        sourceFile = "/etc/llmug/compose/open-webui.yml";
      })
      // {
        after = [
          "network-online.target"
          "llmug-ollama.service"
        ];
        wants = [
          "network-online.target"
          "llmug-ollama.service"
        ];
      };
  };

  networking.firewall.allowedTCPPorts = [
    18080
    21434
    13000
  ];
}

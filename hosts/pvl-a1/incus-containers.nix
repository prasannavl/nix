{
  config,
  inputs,
  pkgs,
  ...
}: let
  incus = "${config.virtualisation.incus.package.client}/bin/incus";
  llmugMetadata = inputs.self.nixosConfigurations.llmug-rivendell.config.system.build.metadata;
  llmugRootfs = inputs.self.nixosConfigurations.llmug-rivendell.config.system.build.tarball;
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/incus-services 0750 root root -"
    "d /var/lib/incus-services/open-webui 0750 root root -"
    "d /var/lib/incus-services/ollama 0750 root root -"
    "d /var/lib/incus-services/llmug-rivendell 0750 root root -"
  ];

  systemd.services.incus-remote-docker = {
    description = "Ensure docker OCI remote exists for Incus";
    wantedBy = ["multi-user.target"];
    after = ["incus.service" "network-online.target"];
    wants = ["incus.service" "network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      coreutils
      gnugrep
      gnused
      config.virtualisation.incus.package.client
    ];
    script = ''
      set -euo pipefail

      if ! ${incus} remote list -f csv,noheader -c n | grep -Fxq docker; then
        ${incus} remote add docker https://docker.io --protocol=oci --public
      fi
    '';
  };

  systemd.services.incus-remote-ghcr = {
    description = "Ensure ghcr OCI remote exists for Incus";
    wantedBy = ["multi-user.target"];
    after = ["incus.service" "network-online.target"];
    wants = ["incus.service" "network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      coreutils
      gnugrep
      gnused
      config.virtualisation.incus.package.client
    ];
    script = ''
      set -euo pipefail

      if ! ${incus} remote list -f csv,noheader -c n | grep -Fxq ghcr; then
        ${incus} remote add ghcr https://ghcr.io --protocol=oci --public
      fi
    '';
  };

  systemd.services.incus-image-llmug-rivendell = {
    description = "Import/update llmug-rivendell NixOS image into Incus";
    wantedBy = ["multi-user.target"];
    after = ["incus.service"];
    wants = ["incus.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      coreutils
      findutils
      gnugrep
      config.virtualisation.incus.package.client
    ];
    script = ''
      set -euo pipefail

      metadata_file="$(find ${llmugMetadata}/tarball -maxdepth 1 -name '*.tar.xz' | head -n1)"
      rootfs_file="$(find ${llmugRootfs}/tarball -maxdepth 1 -name '*.tar.xz' | head -n1)"
      if [ -z "$metadata_file" ] || [ -z "$rootfs_file" ]; then
        echo "Failed to locate llmug-rivendell metadata/rootfs tarballs" >&2
        exit 1
      fi

      if ! ${incus} image info local:llmug-rivendell-nixos >/dev/null 2>&1; then
        ${incus} image import "$metadata_file" "$rootfs_file" --alias llmug-rivendell-nixos
      fi
    '';
  };

  systemd.services.incus-nginx-container = {
    description = "Ensure nginx container is present and running in Incus";
    wantedBy = ["multi-user.target"];
    after = ["incus.service" "network-online.target" "incus-remote-docker.service"];
    wants = ["incus.service" "network-online.target" "incus-remote-docker.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [config.virtualisation.incus.package.client];
    script = ''
      set -euo pipefail

      if ! ${incus} info nginx-container >/dev/null 2>&1; then
        ${incus} launch docker:library/nginx:latest nginx-container
      fi

      ${incus} config device remove nginx-container http >/dev/null 2>&1 || true
      ${incus} config device add nginx-container http proxy listen=tcp:0.0.0.0:8080 connect=tcp:127.0.0.1:80
      ${incus} start nginx-container >/dev/null 2>&1 || true
    '';
  };

  systemd.services.incus-ollama = {
    description = "Ensure Ollama container is present and running in Incus";
    wantedBy = ["multi-user.target"];
    after = ["incus.service" "network-online.target" "incus-remote-docker.service"];
    wants = ["incus.service" "network-online.target" "incus-remote-docker.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [config.virtualisation.incus.package.client];
    script = ''
      set -euo pipefail

      if ! ${incus} info ollama >/dev/null 2>&1; then
        ${incus} launch docker:ollama/ollama:latest ollama
      fi

      ${incus} config device remove ollama api >/dev/null 2>&1 || true
      ${incus} config device add ollama api proxy listen=tcp:0.0.0.0:11434 connect=tcp:127.0.0.1:11434

      ${incus} config device remove ollama ollama-data >/dev/null 2>&1 || true
      ${incus} config device add ollama ollama-data disk source=/var/lib/incus-services/ollama path=/root/.ollama

      ${incus} config device remove ollama gpu >/dev/null 2>&1 || true
      ${incus} config device add ollama gpu gpu

      ${incus} start ollama >/dev/null 2>&1 || true
    '';
  };

  systemd.services.incus-open-webui = {
    description = "Ensure Open WebUI container is present and running in Incus";
    wantedBy = ["multi-user.target"];
    after = [
      "incus.service"
      "network-online.target"
      "incus-remote-docker.service"
      "incus-remote-ghcr.service"
      "incus-ollama.service"
    ];
    wants = [
      "incus.service"
      "network-online.target"
      "incus-remote-docker.service"
      "incus-remote-ghcr.service"
      "incus-ollama.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      coreutils
      gnused
      config.virtualisation.incus.package.client
    ];
    script = ''
      set -euo pipefail

      if ! ${incus} info open-webui >/dev/null 2>&1; then
        ${incus} launch ghcr:open-webui/open-webui:main open-webui
      fi

      bridge_addr="$(${incus} network get incusbr0 ipv4.address | cut -d/ -f1)"
      ${incus} config set open-webui environment.OLLAMA_BASE_URL "http://$bridge_addr:11434"

      ${incus} config device remove open-webui http >/dev/null 2>&1 || true
      ${incus} config device add open-webui http proxy listen=tcp:0.0.0.0:3000 connect=tcp:127.0.0.1:8080

      ${incus} config device remove open-webui open-webui-data >/dev/null 2>&1 || true
      ${incus} config device add open-webui open-webui-data disk source=/var/lib/incus-services/open-webui path=/app/backend/data

      ${incus} start open-webui >/dev/null 2>&1 || true
    '';
  };

  systemd.services.incus-llmug-rivendell = {
    description = "Ensure llmug-rivendell container is present and running in Incus";
    wantedBy = ["multi-user.target"];
    after = [
      "incus.service"
      "network-online.target"
      "incus-image-llmug-rivendell.service"
    ];
    wants = [
      "incus.service"
      "network-online.target"
      "incus-image-llmug-rivendell.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [config.virtualisation.incus.package.client];
    script = ''
      set -euo pipefail

      if ! ${incus} info llmug-rivendell >/dev/null 2>&1; then
        ${incus} launch local:llmug-rivendell-nixos llmug-rivendell -c security.privileged=false
      fi

      ${incus} config device remove llmug-rivendell ssh >/dev/null 2>&1 || true
      ${incus} config device add llmug-rivendell ssh proxy listen=tcp:0.0.0.0:2222 connect=tcp:127.0.0.1:22

      ${incus} config device remove llmug-rivendell state >/dev/null 2>&1 || true
      ${incus} config device add llmug-rivendell state disk source=/var/lib/incus-services/llmug-rivendell path=/var/lib

      ${incus} config device remove llmug-rivendell gpu >/dev/null 2>&1 || true
      ${incus} config device add llmug-rivendell gpu gpu

      ${incus} start llmug-rivendell >/dev/null 2>&1 || true
    '';
  };

  networking.firewall.allowedTCPPorts = [
    8080
    11434
    3000
    2222
  ];
}

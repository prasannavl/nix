{
  config,
  inputs,
  ...
}: let
  incus = "${config.virtualisation.incus.package.client}/bin/incus";
  llmugLabel = inputs.self.nixosConfigurations.llmug-rivendell.config.system.nixos.label;
  llmugSystem = inputs.self.nixosConfigurations.llmug-rivendell.pkgs.stdenv.hostPlatform.system;
  llmugImageFile = "nixos-image-${llmugLabel}-${llmugSystem}.tar.xz";
  llmugMetadata = inputs.self.nixosConfigurations.llmug-rivendell.config.system.build.metadata;
  llmugRootfs = inputs.self.nixosConfigurations.llmug-rivendell.config.system.build.tarball;
  llmugMetadataFile = "${llmugMetadata}/tarball/${llmugImageFile}";
  llmugRootfsFile = "${llmugRootfs}/tarball/${llmugImageFile}";
in {
  systemd.tmpfiles.rules = [
    "d /srv 0755 root root -"
    "d /srv/llmug-rivendell 0750 root root -"
  ];

  systemd.services.incus-image-llmug-rivendell = {
    description = "Import/update llmug-rivendell NixOS image into Incus";
    wantedBy = ["multi-user.target"];
    after = ["incus-preseed.service"];
    wants = ["incus-preseed.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [config.virtualisation.incus.package.client];
    script = ''
      set -euo pipefail

      image_source="${llmugMetadataFile}|${llmugRootfsFile}"

      if [ ! -f ${llmugMetadataFile} ] || [ ! -f ${llmugRootfsFile} ]; then
        echo "Missing llmug-rivendell image tarballs:" >&2
        echo "  ${llmugMetadataFile}" >&2
        echo "  ${llmugRootfsFile}" >&2
        exit 1
      fi

      current_source="$(${incus} image get-property local:llmug-rivendell-nixos user.nix-image-id 2>/dev/null || true)"
      if [ "$current_source" = "$image_source" ] && ${incus} image info local:llmug-rivendell-nixos >/dev/null 2>&1; then
        exit 0
      fi

      if ${incus} image info local:llmug-rivendell-nixos >/dev/null 2>&1; then
        ${incus} image delete local:llmug-rivendell-nixos
      fi

      ${incus} image import ${llmugMetadataFile} ${llmugRootfsFile} --alias llmug-rivendell-nixos
      ${incus} image set-property local:llmug-rivendell-nixos user.nix-image-id "$image_source"

      # Stage image update for the existing instance. It will be applied only
      # when the instance is already stopped by normal operations.
      if ${incus} info llmug-rivendell >/dev/null 2>&1; then
        ${incus} config set llmug-rivendell user.nix-pending-image-id "$image_source"
      fi
    '';
  };

  systemd.services.incus-llmug-rivendell = {
    description = "Ensure llmug-rivendell container is present and running in Incus";
    wantedBy = ["multi-user.target"];
    after = [
      "incus-preseed.service"
      "network-online.target"
      "incus-image-llmug-rivendell.service"
    ];
    wants = [
      "incus-preseed.service"
      "network-online.target"
      "incus-image-llmug-rivendell.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "-${incus} stop llmug-rivendell";
    };
    path = [config.virtualisation.incus.package.client];
    script = ''
      set -euo pipefail

      image_source="${llmugMetadataFile}|${llmugRootfsFile}"

      created=0
      if ! ${incus} info llmug-rivendell >/dev/null 2>&1; then
        ${incus} create local:llmug-rivendell-nixos llmug-rivendell
        created=1
      fi

      if [ "$created" -eq 1 ]; then
        ${incus} config set llmug-rivendell security.privileged false
        ${incus} config set llmug-rivendell security.nesting true
        ${incus} config device add llmug-rivendell ssh proxy listen=tcp:0.0.0.0:2223 connect=tcp:127.0.0.1:22
        ${incus} config device add llmug-rivendell state disk source=/srv/llmug-rivendell path=/var/lib shift=true
        ${incus} config device add llmug-rivendell gpu gpu
      fi

      pending_source="$(${incus} config get llmug-rivendell user.nix-pending-image-id 2>/dev/null || true)"
      status="$(${incus} list llmug-rivendell --format csv -c s 2>/dev/null || true)"
      if [ -n "$pending_source" ] && [ "$pending_source" = "$image_source" ] && [ "$status" = "STOPPED" ]; then
        ${incus} rebuild local:llmug-rivendell-nixos llmug-rivendell
        ${incus} config unset llmug-rivendell user.nix-pending-image-id
      fi

      ${incus} start llmug-rivendell >/dev/null 2>&1 || true
    '';
  };

  networking.firewall.allowedTCPPorts = [
    2223
  ];
}

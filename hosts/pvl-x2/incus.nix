{
  config,
  inputs,
  lib,
  ...
}: let
  incus = "${config.virtualisation.incus.package.client}/bin/incus";
  baseImage = inputs.self.nixosImages.incus-base;
  baseAlias = "nixos-incus-base";
  baseLabel = baseImage.config.system.nixos.label;
  baseSystem = baseImage.pkgs.stdenv.hostPlatform.system;
  baseImageFile = "nixos-image-${baseLabel}-${baseSystem}.tar.xz";
  baseMetadata = baseImage.config.system.build.metadata;
  baseRootfs = baseImage.config.system.build.tarball;
  baseMetadataFile = "${baseMetadata}/tarball/${baseImageFile}";
  baseRootfsFile = "${baseRootfs}/tarball/${baseImageFile}";
  baseImageSource = "${baseMetadataFile}|${baseRootfsFile}";

  incusMachines = {
    llmug-rivendell = {
      ipv4Address = "10.10.20.10";
      stateDir = "/var/lib/machines/llmug-rivendell";
      stateDirMode = "0750";
      extraCreateCommands = [
        "${incus} config device add llmug-rivendell gpu gpu"
        "${incus} config device add llmug-rivendell kfd unix-char source=/dev/kfd path=/dev/kfd"
      ];
    };
  };

  mkMachineTmpfile = _: machine: "d ${machine.stateDir} ${machine.stateDirMode} root root -";

  mkMachineService = name: machine:
    lib.nameValuePair "incus-${name}" {
      description = "Ensure ${name} container is present and running in Incus";
      wantedBy = ["multi-user.target"];
      after = [
        "incus-preseed.service"
        "network-online.target"
        "incus-image-base.service"
      ];
      wants = [
        "incus-preseed.service"
        "network-online.target"
        "incus-image-base.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "-${incus} stop ${name}";
      };
      path = [config.virtualisation.incus.package.client];
      script = ''
        set -euo pipefail

        created=0
        if ! ${incus} info ${name} >/dev/null 2>&1; then
          ${incus} create local:${baseAlias} ${name}
          created=1
        fi

        if [ "$created" -eq 1 ]; then
          ${incus} config set ${name} security.privileged false
          ${incus} config set ${name} security.nesting true
          ${incus} config device add ${name} state disk source=${machine.stateDir} path=/var/lib shift=true
          ${lib.concatStringsSep "\n          " machine.extraCreateCommands}
          # Keep a stable container address outside the bridge DHCP allocation.
          ${incus} config device override ${name} eth0 ipv4.address=${machine.ipv4Address}
        else
          ${incus} config device set ${name} eth0 ipv4.address=${machine.ipv4Address}
        fi

        ${incus} start ${name} >/dev/null 2>&1 || true
      '';
    };
in {
  virtualisation.incus.preseed = {
    config = {
      "core.https_address" = "[::]:8443";
    };

    networks = [
      {
        config = {
          "ipv4.address" = "10.10.20.1/24";
          "ipv4.dhcp.ranges" = "10.10.20.100-10.10.20.199";
          "ipv4.nat" = "true";
          "ipv6.address" = "auto";
        };
        description = "";
        name = "incusbr0";
        type = "";
        project = "default";
      }
    ];

    storage_pools = [
      {
        config = {
          source = "/var/lib/incus/storage-pools/default";
        };
        description = "";
        name = "default";
        driver = "btrfs";
      }
    ];

    storage_volumes = [];

    profiles = [
      {
        config = {};
        description = "";
        devices = {
          eth0 = {
            name = "eth0";
            network = "incusbr0";
            type = "nic";
          };
          root = {
            path = "/";
            pool = "default";
            type = "disk";
          };
        };
        name = "default";
        project = "default";
      }
    ];

    projects = [];
    certificates = [];
    cluster = null;
  };

  systemd.tmpfiles.rules =
    [
      "d /var/lib/machines 0755 root root -"
    ]
    ++ lib.mapAttrsToList mkMachineTmpfile incusMachines;

  systemd.services =
    {
      incus-image-base = {
        description = "Import/update generic base NixOS image into Incus";
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

          if [ ! -f ${baseMetadataFile} ] || [ ! -f ${baseRootfsFile} ]; then
            echo "Missing base image tarballs:" >&2
            echo "  ${baseMetadataFile}" >&2
            echo "  ${baseRootfsFile}" >&2
            exit 1
          fi

          current_source="$(${incus} image get-property local:${baseAlias} user.base-image-id 2>/dev/null || true)"
          if [ "$current_source" = "${baseImageSource}" ] && ${incus} image info local:${baseAlias} >/dev/null 2>&1; then
            exit 0
          fi

          if ${incus} image info local:${baseAlias} >/dev/null 2>&1; then
            ${incus} image delete local:${baseAlias}
          fi

          ${incus} image import ${baseMetadataFile} ${baseRootfsFile} --alias ${baseAlias}
          ${incus} image set-property local:${baseAlias} user.base-image-id "${baseImageSource}"
        '';
      };
    }
    // lib.mapAttrs' mkMachineService incusMachines;
}

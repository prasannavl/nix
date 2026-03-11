{
  config,
  inputs,
  lib,
  ...
}: let
  incus = "${config.virtualisation.incus.package.client}/bin/incus";
  bootstrapImage = inputs.self.nixosImages.incus-bootstrap;
  bootstrapAlias = "nixos-incus-bootstrap";
  bootstrapLabel = bootstrapImage.config.system.nixos.label;
  bootstrapSystem = bootstrapImage.pkgs.stdenv.hostPlatform.system;
  bootstrapImageFile = "nixos-image-${bootstrapLabel}-${bootstrapSystem}.tar.xz";
  bootstrapMetadata = bootstrapImage.config.system.build.metadata;
  bootstrapRootfs = bootstrapImage.config.system.build.tarball;
  bootstrapMetadataFile = "${bootstrapMetadata}/tarball/${bootstrapImageFile}";
  bootstrapRootfsFile = "${bootstrapRootfs}/tarball/${bootstrapImageFile}";
  bootstrapImageSource = "${bootstrapMetadataFile}|${bootstrapRootfsFile}";

  incusMachines = {
    llmug-rivendell = {
      ipv4Address = "10.42.0.23";
      stateDir = "/var/lib/machines/llmug-rivendell";
      stateDirMode = "0750";
      extraCreateCommands = [
        "${incus} config device add llmug-rivendell gpu gpu"
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
        "incus-image-bootstrap.service"
      ];
      wants = [
        "incus-preseed.service"
        "network-online.target"
        "incus-image-bootstrap.service"
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
          ${incus} create local:${bootstrapAlias} ${name}
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
          "ipv4.address" = "10.42.0.1/24";
          "ipv4.dhcp.ranges" = "10.42.0.100-10.42.0.199";
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
      incus-image-bootstrap = {
        description = "Import/update generic bootstrap NixOS image into Incus";
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

          if [ ! -f ${bootstrapMetadataFile} ] || [ ! -f ${bootstrapRootfsFile} ]; then
            echo "Missing bootstrap image tarballs:" >&2
            echo "  ${bootstrapMetadataFile}" >&2
            echo "  ${bootstrapRootfsFile}" >&2
            exit 1
          fi

          current_source="$(${incus} image get-property local:${bootstrapAlias} user.bootstrap-image-id 2>/dev/null || true)"
          if [ "$current_source" = "${bootstrapImageSource}" ] && ${incus} image info local:${bootstrapAlias} >/dev/null 2>&1; then
            exit 0
          fi

          if ${incus} image info local:${bootstrapAlias} >/dev/null 2>&1; then
            ${incus} image delete local:${bootstrapAlias}
          fi

          ${incus} image import ${bootstrapMetadataFile} ${bootstrapRootfsFile} --alias ${bootstrapAlias}
          ${incus} image set-property local:${bootstrapAlias} user.bootstrap-image-id "${bootstrapImageSource}"
        '';
      };
    }
    // lib.mapAttrs' mkMachineService incusMachines;
}

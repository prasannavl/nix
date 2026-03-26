{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.incusMachines;
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

  hasMachines = cfg.machines != {};

  deviceType = lib.types.submodule (_: {
    options = {
      type = lib.mkOption {
        type = lib.types.str;
        default = "disk";
        description = "Device type: disk (default), gpu, unix-char, nic, etc.";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source path (host dir, volume name, or device path).";
      };
      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Mount/device path inside the container.";
      };
      shift = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable UID/GID shift for disk mounts.";
      };
      pool = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Storage pool for volume-backed disk devices.";
      };
      removalPolicy = lib.mkOption {
        type = lib.types.enum ["keep" "delete"];
        default = "keep";
        description = "For disk devices: 'delete' wipes the source dir on container delete-all; 'keep' (default) preserves it.";
      };
      extraProperties = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Additional incus device properties not covered by top-level fields.";
      };
    };
  });

  machineType = lib.types.submodule (_: {
    options = {
      ipv4Address = lib.mkOption {
        type = lib.types.str;
        description = "Static IPv4 address (outside the bridge DHCP range).";
      };
      devices = lib.mkOption {
        type = lib.types.attrsOf deviceType;
        default = {};
        description = "Incus devices attached to this container.";
      };
      config = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Incus container config keys. Changes trigger stop+delete+recreate.";
      };
      removalPolicy = lib.mkOption {
        type = lib.types.enum ["stop-only" "delete-container" "delete-all"];
        default = "delete-container";
        description = "What happens when this machine is removed from config.";
      };
      bootTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Bump to force a restart (stop+start) on next rebuild.";
      };
      recreateTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Bump to force a full recreate (stop+delete+create) on next rebuild.";
      };
    };
  });

  isHostPath = source: source != null && lib.hasPrefix "/" source;
  isHostPathDisk = dev: dev.type == "disk" && isHostPath dev.source;
  isManagedHostDir = dev: isHostPathDisk dev && !lib.hasPrefix "/dev/" dev.source;
  isVolumeBackedDisk = dev: dev.type == "disk" && dev.source != null && !isHostPath dev.source;

  # Resolve a device submodule into the flat property map incus expects.
  resolveDeviceProperties = _name: dev: let
    base = {inherit (dev) type;};
    withSource = lib.optionalAttrs (dev.source != null) {inherit (dev) source;};
    withPath = lib.optionalAttrs (dev.path != null) {inherit (dev) path;};
    withShift = lib.optionalAttrs (dev.type == "disk" && dev.shift) {shift = "true";};
    withPool = lib.optionalAttrs (isVolumeBackedDisk dev) {inherit (dev) pool;};
  in
    base // withSource // withPath // withShift // withPool // dev.extraProperties;

  # Partition devices: disk devices are synced in-place, all others are
  # create-only (added at creation, changes trigger recreate).
  createOnlyDevices = machine:
    lib.filterAttrs (_: dev: dev.type != "disk") machine.devices;
  syncableDevices = machine:
    lib.filterAttrs (_: dev: dev.type == "disk") machine.devices;

  # Config hash includes container config AND create-only devices so that
  # changes to either trigger a full recreate.
  configHash = machine:
    builtins.hashString "sha256" (builtins.toJSON {
      inherit (machine) config;
      createOnlyDevices = lib.mapAttrs resolveDeviceProperties (createOnlyDevices machine);
    });

  # Only disk devices are synced in-place.
  diskDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs resolveDeviceProperties (syncableDevices machine));

  # Create-only device spec for the creation script.
  createOnlyDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs resolveDeviceProperties (createOnlyDevices machine));

  # Collect user.* metadata to store on the container at creation time.
  mkUserMetadata = _name: machine:
    {
      "user.managed-by" = "nixos";
      "user.config-hash" = configHash machine;
      "user.boot-tag" = machine.bootTag;
      "user.recreate-tag" = machine.recreateTag;
      "user.removal-policy" = machine.removalPolicy;
    }
    // lib.concatMapAttrs (
      devName: dev:
        lib.optionalAttrs (dev.type == "disk") {
          "user.device.${devName}.removal-policy" = dev.removalPolicy;
        }
        // lib.optionalAttrs (isManagedHostDir dev) {
          "user.device.${devName}.source" = dev.source;
        }
    )
    machine.devices;

  # JSON list of declared machine names for the GC script.
  declaredMachinesJson = builtins.toJSON (builtins.attrNames cfg.machines);

  # Per-machine systemd service.
  mkMachineService = name: machine: let
    hash = configHash machine;
    diskDevSpec = diskDeviceSpecJson machine;
    createOnlyDevSpec = createOnlyDeviceSpecJson machine;
    userMeta = mkUserMetadata name machine;
    setMetaCmds = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "  ${incus} config set ${name} ${k}=${lib.escapeShellArg v}") userMeta
    );
    setConfigCmds = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "  ${incus} config set ${name} ${k}=${lib.escapeShellArg v}") machine.config
    );
  in
    lib.nameValuePair "incus-${name}" {
      description = "Incus container lifecycle for ${name}";
      wantedBy = ["multi-user.target"];
      after = [
        "incus-preseed.service"
        "network-online.target"
        "incus-image-base.service"
        "incus-machines-gc.service"
      ];
      wants = [
        "incus-preseed.service"
        "network-online.target"
        "incus-image-base.service"
        "incus-machines-gc.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "-${incus} stop ${name}";
      };
      path = [config.virtualisation.incus.package.client pkgs.jq];
      script = ''
        set -euo pipefail

        json_keys() {
          local json="$1"
          printf '%s' "$json" | jq -r 'keys[]'
        }

        json_property_keys() {
          local json="$1"
          printf '%s' "$json" | jq -r 'keys[] | select(. != "type")'
        }

        add_device_from_props() {
          local instance_name="$1" device_name="$2" props_json="$3"
          local device_type assignment=""
          local -a add_args=()

          device_type="$(printf '%s' "$props_json" | jq -r '.type')"
          while IFS= read -r assignment; do
            add_args+=("$assignment")
          done < <(
            printf '%s' "$props_json" \
              | jq -r 'to_entries[] | select(.key != "type") | "\(.key)=\(.value)"'
          )

          ${incus} config device add "$instance_name" "$device_name" "$device_type" "''${add_args[@]}"
        }

        desired_config_hash=${lib.escapeShellArg hash}
        desired_boot_tag=${lib.escapeShellArg machine.bootTag}
        desired_recreate_tag=${lib.escapeShellArg machine.recreateTag}

        needs_create=0
        needs_recreate=0
        needs_restart=0

        if ! ${incus} info ${name} >/dev/null 2>&1; then
          needs_create=1
        else
          current_config_hash="$(${incus} config get ${name} user.config-hash 2>/dev/null || true)"
          current_recreate_tag="$(${incus} config get ${name} user.recreate-tag 2>/dev/null || true)"
          current_boot_tag="$(${incus} config get ${name} user.boot-tag 2>/dev/null || true)"

          # recreateTag: always compare — an explicit bump (even from empty) is intentional.
          # config-hash: only compare if previously set — empty means legacy container, adopt it.
          # bootTag: only compare if previously set.
          if [ "$current_recreate_tag" != "$desired_recreate_tag" ] || \
             { [ -n "$current_config_hash" ] && [ "$current_config_hash" != "$desired_config_hash" ]; }; then
            needs_recreate=1
          elif [ -n "$current_boot_tag" ] && [ "$current_boot_tag" != "$desired_boot_tag" ]; then
            needs_restart=1
          fi
        fi

        # Recreate: stop + delete + create fresh.
        if [ "$needs_recreate" -eq 1 ]; then
          echo "Recreating ${name} (config hash or recreate tag changed)..."
          ${incus} stop ${name} --force 2>/dev/null || true
          ${incus} delete ${name} --force 2>/dev/null || true
          needs_create=1
        fi

        # Create from base image.
        if [ "$needs_create" -eq 1 ]; then
          echo "Creating ${name} from base image..."
          ${incus} create local:${baseAlias} ${name}

          # Apply container config.
        ${setConfigCmds}

          # Apply user metadata.
        ${setMetaCmds}

          # Override eth0 IP.
          ${incus} config device override ${name} eth0 ipv4.address=${machine.ipv4Address}

          # Add create-only devices (gpu, unix-char, etc.) — only at creation.
          echo "Adding create-only devices for ${name}..."
          create_only_devices='${createOnlyDevSpec}'
          mapfile -t create_only_device_names < <(json_keys "$create_only_devices")
          for dev in "''${create_only_device_names[@]}"; do
            props="$(printf '%s' "$create_only_devices" | jq -c --arg d "$dev" '.[$d]')"
            echo "  Adding device $dev ($(printf '%s' "$props" | jq -r '.type'))"
            add_device_from_props ${name} "$dev" "$props"
          done
        fi

        current_devices="$(${incus} query /1.0/instances/${name} --raw 2>/dev/null | \
          jq -c '.metadata.devices // {}' 2>/dev/null || echo '{}')"

        # Sync disk devices in-place.
        echo "Syncing disk devices for ${name}..."
        desired_disks='${diskDevSpec}'
        mapfile -t current_disk_names < <(
          printf '%s' "$current_devices" \
            | jq -r 'to_entries[] | select(.value.type == "disk") | .key' 2>/dev/null \
            || true
        )

        # Remove disk devices not in desired set.
        for dev in "''${current_disk_names[@]}"; do
          if ! printf '%s' "$desired_disks" | jq -e --arg d "$dev" 'has($d)' >/dev/null 2>&1; then
            echo "  Removing disk device $dev"
            ${incus} config device remove ${name} "$dev" 2>/dev/null || true
          fi
        done

        # Add or update disk devices.
        mapfile -t desired_disk_names < <(json_keys "$desired_disks")
        for dev in "''${desired_disk_names[@]}"; do
          desired_props="$(printf '%s' "$desired_disks" | jq -c --arg d "$dev" '.[$d]')"
          current_props="$(printf '%s' "$current_devices" | jq -c --arg d "$dev" '.[$d] // null')"
          dev_exists=0
          if [ "$current_props" != "null" ]; then
            dev_exists=1
          fi

          # Auto-create storage volume if this is a volume-backed disk.
          dev_source="$(echo "$desired_props" | jq -r '.source // ""')"
          dev_pool="$(echo "$desired_props" | jq -r '.pool // ""')"
          if [ -n "$dev_source" ] && [ -n "$dev_pool" ]; then
            if ! ${incus} storage volume show "$dev_pool" "$dev_source" >/dev/null 2>&1; then
              echo "  Creating storage volume $dev_pool/$dev_source"
              ${incus} storage volume create "$dev_pool" "$dev_source"
            fi
          fi

          if [ "$dev_exists" -eq 0 ]; then
            echo "  Adding disk device $dev"
            add_device_from_props ${name} "$dev" "$desired_props"
          else
            # Remove stale properties first so disk devices stay declarative.
            mapfile -t current_prop_keys < <(json_property_keys "$current_props")
            for key in "''${current_prop_keys[@]}"; do
              if ! printf '%s' "$desired_props" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
                ${incus} config device unset ${name} "$dev" "$key"
              fi
            done

            # Device exists, update changed properties.
            mapfile -t desired_prop_keys < <(json_property_keys "$desired_props")
            for key in "''${desired_prop_keys[@]}"; do
              desired_val="$(printf '%s' "$desired_props" | jq -r --arg k "$key" '.[$k]')"
              ${incus} config device set ${name} "$dev" "$key" "$desired_val"
            done
          fi
        done

        # Update IP address (always sync).
        ${incus} config device set ${name} eth0 ipv4.address=${machine.ipv4Address} 2>/dev/null || \
          ${incus} config device override ${name} eth0 ipv4.address=${machine.ipv4Address} 2>/dev/null || true

        # Update metadata.
        ${incus} config set ${name} user.config-hash=${lib.escapeShellArg hash}
        ${incus} config set ${name} user.boot-tag=${lib.escapeShellArg machine.bootTag}
        ${incus} config set ${name} user.recreate-tag=${lib.escapeShellArg machine.recreateTag}

        # Restart if boot tag changed (and we didn't already recreate).
        if [ "$needs_restart" -eq 1 ]; then
          echo "Restarting ${name} (boot tag changed)..."
          ${incus} stop ${name} --force 2>/dev/null || true
        fi

        # Start the container.
        ${incus} start ${name} 2>/dev/null || true
      '';
    };

  # Tmpfiles for host-path disk devices that start with /.
  mkDeviceTmpfiles = _name: machine:
    lib.concatLists (
      lib.mapAttrsToList (
        _devName: dev:
          lib.optional (isManagedHostDir dev)
          "d ${dev.source} 0755 root root -"
      )
      machine.devices
    );
in {
  options.services.incusMachines = {
    imageTag = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = "Bump to force re-import of the shared Incus base image on next rebuild.";
    };

    reconcileOnActivation = lib.mkOption {
      type = lib.types.enum ["off" "best-effort" "strict"];
      default = "best-effort";
      description = ''
        Whether parent-host activation should reconcile declared Incus guests.
        `off` disables activation-time reconcile, `best-effort` retries missing
        or stopped guests without failing the parent activation, and `strict`
        makes guest reconcile failures abort activation.
      '';
    };

    machines = lib.mkOption {
      type = lib.types.attrsOf machineType;
      default = {};
      description = "Declarative Incus containers with lifecycle management.";
    };
  };

  config = lib.mkIf hasMachines {
    services.incusMachines.reconcileOnActivation = lib.mkDefault (
      if config.boot.isContainer
      then "off"
      # Temporarily switch this off since this can
      # brick physical machines from booting and not going beyond initrd
      # if there's failure on activation requiring manual rescue.
      else "off"
    );

    virtualisation.incus = {
      enable = lib.mkDefault true;
      package = lib.mkDefault pkgs.incus;
      ui.enable = lib.mkDefault true;
    };

    system.activationScripts.incusMachinesReconcile = lib.mkIf (cfg.reconcileOnActivation != "off") (
      lib.stringAfter ["etc"] ''
        set -eu

        if ! ${incus} info >/dev/null 2>&1; then
          exit 0
        fi

        declared_machines='${declaredMachinesJson}'
        reconcile_mode=${lib.escapeShellArg cfg.reconcileOnActivation}

        echo "$declared_machines" | ${pkgs.jq}/bin/jq -r '.[]' | while IFS= read -r name; do
          [ -n "$name" ] || continue

          status="$(
            ${incus} list "$name" --format json 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r 'if length == 0 then "missing" else .[0].status // "unknown" end' \
              2>/dev/null \
              || printf 'missing\n'
          )"

          if [ "$status" != "Running" ]; then
            echo "Reconciling Incus guest $name (status: $status)"
            if ! ${pkgs.systemd}/bin/systemctl restart "incus-$name.service"; then
              if [ "$reconcile_mode" = "strict" ]; then
                exit 1
              fi
              echo "Best-effort guest reconcile failed for $name; continuing parent activation" >&2
            fi
          fi
        done
      ''
    );

    systemd.tmpfiles.rules =
      lib.concatLists (lib.mapAttrsToList mkDeviceTmpfiles cfg.machines);

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
            current_rebuild_tag="$(${incus} image get-property local:${baseAlias} user.base-image-rebuild-tag 2>/dev/null || true)"
            desired_rebuild_tag=${lib.escapeShellArg cfg.imageTag}

            if [ "$current_source" = "${baseImageSource}" ] && \
               [ "$current_rebuild_tag" = "$desired_rebuild_tag" ] && \
               ${incus} image info local:${baseAlias} >/dev/null 2>&1; then
              exit 0
            fi

            if ${incus} image info local:${baseAlias} >/dev/null 2>&1; then
              ${incus} image delete local:${baseAlias}
            fi

            ${incus} image import ${baseMetadataFile} ${baseRootfsFile} --alias ${baseAlias}
            ${incus} image set-property local:${baseAlias} user.base-image-id "${baseImageSource}"
            ${incus} image set-property local:${baseAlias} user.base-image-rebuild-tag "$desired_rebuild_tag"
          '';
        };

        incus-machines-gc = {
          description = "Garbage-collect Incus containers no longer declared in NixOS config";
          wantedBy = ["multi-user.target"];
          after = [
            "incus-preseed.service"
            "incus-image-base.service"
          ];
          wants = [
            "incus-preseed.service"
            "incus-image-base.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [config.virtualisation.incus.package.client pkgs.jq];
          script = ''
            set -euo pipefail

            declared_machines='${declaredMachinesJson}'

            # List all containers managed by us.
            all_containers="$(${incus} list --format json 2>/dev/null || echo '[]')"

            echo "$all_containers" | jq -c '.[]' | while IFS= read -r row; do
              cname="$(echo "$row" | jq -r '.name')"
              managed="$(echo "$row" | jq -r '.config["user.managed-by"] // ""')"

              [ "$managed" = "nixos" ] || continue

              # Check if still declared.
              if echo "$declared_machines" | jq -e --arg n "$cname" 'index($n) != null' >/dev/null 2>&1; then
                continue
              fi

              removal_policy="$(echo "$row" | jq -r '.config["user.removal-policy"] // "delete-container"')"

              echo "GC: container $cname (policy: $removal_policy)"

              case "$removal_policy" in
                stop-only)
                  ${incus} stop "$cname" --force 2>/dev/null || true
                  ;;
                delete-container)
                  ${incus} delete "$cname" --force 2>/dev/null || true
                  ;;
                delete-all)
                  # Collect source dirs to wipe before deleting the container.
                  mapfile -t dirs_to_remove < <(
                    echo "$row" | jq -r '
                      .config as $cfg
                      | to_entries[]
                      | select(.key | test("^user\\.device\\..+\\.removal-policy$"))
                      | select(.value == "delete")
                      | (.key | capture("^user\\.device\\.(?<name>.*)\\.removal-policy$").name) as $name
                      | $cfg["user.device.\($name).source"] // empty
                    '
                  )

                  ${incus} delete "$cname" --force 2>/dev/null || true

                  for dir in "''${dirs_to_remove[@]}"; do
                    [ -d "$dir" ] || continue
                    echo "  Removing source dir: $dir"
                    rm -rf "$dir"
                  done
                  ;;
              esac
            done
          '';
        };
      }
      // lib.mapAttrs' mkMachineService cfg.machines;
  };
}

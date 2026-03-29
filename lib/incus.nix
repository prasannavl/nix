{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.incusMachines;
  incus = "${config.virtualisation.incus.package.client}/bin/incus";

  defaultBaseImage = inputs.self.nixosImages.incus-base;
  defaultBaseAlias = "nixos-incus-base";

  hasInstances = cfg.instances != {};

  sanitizeImageAlias = value:
    builtins.replaceStrings
    [
      ":"
      "/"
      " "
      "."
      "_"
    ]
    [
      "-"
      "-"
      "-"
      "-"
      "-"
    ]
    value;

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
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.raw;
        default = null;
        description = ''
          Optional image source for this machine. A string is treated as an
          Incus image reference such as `debian` or `images:debian/12`; a
          non-string value is treated as a NixOS image derivation/system attrset
          to import into local Incus. Defaults to
          `services.incusMachines.defaultImage`.
        '';
      };
      imageAlias = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional stable Incus alias for this machine's image. Defaults to the
          shared default alias when `image` is unset, otherwise
          `nixos-incus-<machine-name>` for local NixOS images and a sanitized
          alias derived from the remote image reference for string images.
        '';
      };
      ipv4Address = lib.mkOption {
        type = lib.types.str;
        description = "Static IPv4 address (outside the bridge DHCP range).";
      };
      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 22;
        description = "SSH port used by readiness settle checks for this guest.";
      };
      waitForSsh = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether settle should wait for TCP reachability on `sshPort` for this
          guest. Disable this for containers that are intentionally not managed
          over SSH.
        '';
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

  # Config hash includes container config, the resolved base-image alias, and
  # create-only devices so that changes to those inputs trigger a full
  # recreate.
  configHash = name: machine:
    builtins.hashString "sha256" (builtins.toJSON {
      inherit (machine) config;
      image = let
        resolvedImage = resolveMachineImage name machine;
      in {
        inherit (resolvedImage) alias createRef imageIdentity;
      };
      createOnlyDevices = lib.mapAttrs resolveDeviceProperties (createOnlyDevices machine);
    });

  # Only disk devices are synced in-place.
  diskDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs resolveDeviceProperties (syncableDevices machine));

  # Create-only device spec for the creation script.
  createOnlyDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs resolveDeviceProperties (createOnlyDevices machine));

  # Collect user.* metadata to store on the container at creation time.
  mkUserMetadata = name: machine:
    {
      "user.managed-by" = "nixos";
      "user.config-hash" = configHash name machine;
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

  resolveMachineImage = name: machine: let
    image =
      if machine.image != null
      then machine.image
      else cfg.defaultImage;
    isRemote = builtins.isString image;
    remoteRef =
      if isRemote
      then
        if lib.hasInfix ":" image
        then image
        else "images:${image}"
      else null;
    alias =
      if machine.imageAlias != null
      then machine.imageAlias
      else if machine.image != null
      then
        if isRemote
        then "incus-${sanitizeImageAlias remoteRef}"
        else "nixos-incus-${name}"
      else cfg.defaultImageAlias;
  in
    if isRemote
    then {
      kind = "remote";
      inherit alias remoteRef;
      createRef = "local:${alias}";
      imageIdentity = "remote:${remoteRef}";
    }
    else let
      imageLabel = image.config.system.nixos.label;
      imageSystem = image.pkgs.stdenv.hostPlatform.system;
      imageFile = "nixos-image-${imageLabel}-${imageSystem}.tar.xz";
      metadata = image.config.system.build.metadata;
      rootfs = image.config.system.build.tarball;
      metadataFile = "${metadata}/tarball/${imageFile}";
      rootfsFile = "${rootfs}/tarball/${imageFile}";
      imageSource = "${metadataFile}|${rootfsFile}";
    in {
      kind = "local";
      inherit alias imageSource metadataFile rootfsFile;
      createRef = "local:${alias}";
      imageIdentity = "local:${imageSource}";
    };

  instanceImages = lib.mapAttrs resolveMachineImage cfg.instances;

  declaredImages =
    builtins.attrValues
    (lib.mapAttrs'
      (_name: image:
        lib.nameValuePair image.alias image)
      instanceImages);

  aliasToMachineNames =
    lib.foldl'
    (acc: name: let
      alias = instanceImages.${name}.alias;
    in
      acc
      // {
        ${alias} = (acc.${alias} or []) ++ [name];
      })
    {}
    (builtins.attrNames instanceImages);

  duplicateImageAliases =
    lib.attrNames
    (lib.filterAttrs (_alias: machineNames: builtins.length machineNames > 1) aliasToMachineNames);

  imageAliasConflicts =
    lib.filter (
      alias: let
        sources =
          lib.unique
          (map (name: instanceImages.${name}.imageIdentity) aliasToMachineNames.${alias});
      in
        builtins.length sources > 1
    )
    duplicateImageAliases;

  ipv4ToMachineNames =
    lib.foldl'
    (acc: name: let
      ipv4Address = cfg.instances.${name}.ipv4Address;
    in
      acc
      // {
        ${ipv4Address} = (acc.${ipv4Address} or []) ++ [name];
      })
    {}
    (builtins.attrNames cfg.instances);

  duplicateIpv4Addresses =
    lib.attrNames
    (lib.filterAttrs (_ipv4Address: machineNames: builtins.length machineNames > 1) ipv4ToMachineNames);

  ipv4AddressConflicts =
    map
    (ipv4Address: "${ipv4Address} -> ${lib.concatStringsSep ", " ipv4ToMachineNames.${ipv4Address}}")
    duplicateIpv4Addresses;

  declaredImagesJson = builtins.toJSON declaredImages;

  # JSON list of declared instance names for the GC script.
  declaredInstancesJson = builtins.toJSON (builtins.attrNames cfg.instances);

  instanceIpv4AddressesJson = builtins.toJSON (
    lib.mapAttrs (_name: instance: instance.ipv4Address) cfg.instances
  );

  instanceSshPortsJson = builtins.toJSON (
    lib.mapAttrs (_name: instance: instance.sshPort) cfg.instances
  );

  instanceWaitForSshJson = builtins.toJSON (
    lib.mapAttrs (_name: instance: instance.waitForSsh) cfg.instances
  );

  machineSelectionArgParser = ''
    selected_json='[]'

    append_instance() {
      local name="$1"
      selected_json="$(
        printf '%s' "$selected_json" \
          | jq -c --arg name "$name" '. + [$name]'
      )"
    }

    parse_machine_selection_args() {
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --all)
            selected_json="$declared_instances"
            shift
            ;;
          --instance|--machine)
            [ "$#" -ge 2 ] || {
              echo "Missing value for $1" >&2
              exit 1
            }
            append_instance "$2"
            shift 2
            ;;
          *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
        esac
      done

      if [ "$selected_json" = "[]" ]; then
        selected_json="$declared_instances"
      fi
    }
  '';

  instanceQueryPathLib = ''
    instance_query_path() {
      local name="$1" encoded_name
      encoded_name="$(jq -nr --arg value "$name" '$value | @uri')"
      printf '%s\n' "/1.0/instances/$encoded_name"
    }
  '';

  reconcilerHelper = pkgs.writeShellApplication {
    name = "incus-machines-reconciler";
    runtimeInputs = [
      config.virtualisation.incus.package.client
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      reconcile_mode=${lib.escapeShellArg cfg.reconcilePolicy}
      declared_instances='${declaredInstancesJson}'
      ${machineSelectionArgParser}
      ${instanceQueryPathLib}
      parse_machine_selection_args "$@"

      if ! incus info >/dev/null 2>&1; then
        if [ "$reconcile_mode" = "strict" ]; then
          echo "Incus daemon is unavailable; reconcile cannot continue" >&2
          exit 1
        fi
        echo "Incus daemon is unavailable; skipping best-effort reconcile" >&2
        exit 0
      fi

      instance_status() {
        local name="$1"

        incus query "$(instance_query_path "$name")" --raw 2>/dev/null \
          | jq -r '.metadata.status // "unknown"' 2>/dev/null \
          || printf 'missing\n'
      }

      echo "$selected_json" | jq -r '.[]' | while IFS= read -r name; do
        [ -n "$name" ] || continue

        if ! printf '%s' "$declared_instances" | jq -e --arg name "$name" 'index($name) != null' >/dev/null; then
          echo "Skipping undeclared Incus instance: $name" >&2
          continue
        fi

        status="$(instance_status "$name")"

        if [ "$status" = "Running" ]; then
          continue
        fi

        echo "Reconciling Incus instance $name (status: $status)"
        if ! systemctl restart "incus-$name.service"; then
          if [ "$reconcile_mode" = "strict" ]; then
            exit 1
          fi
          echo "Best-effort instance reconcile failed for $name; continuing" >&2
        fi
      done
    '';
  };

  settlementHelper = pkgs.writeShellApplication {
    name = "incus-machines-settlement";
    runtimeInputs = [
      config.virtualisation.incus.package.client
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      declared_instances='${declaredInstancesJson}'
      instance_ipv4_addresses='${instanceIpv4AddressesJson}'
      instance_ssh_ports='${instanceSshPortsJson}'
      instance_wait_for_ssh='${instanceWaitForSshJson}'
      timeout_secs=180
      interval_secs=2
      ${machineSelectionArgParser}
      ${instanceQueryPathLib}

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --all|--instance|--machine)
            break
            ;;
          --timeout)
            [ "$#" -ge 2 ] || {
              echo "Missing value for --timeout" >&2
              exit 1
            }
            timeout_secs="$2"
            shift 2
            ;;
          --interval)
            [ "$#" -ge 2 ] || {
              echo "Missing value for --interval" >&2
              exit 1
            }
            interval_secs="$2"
            shift 2
            ;;
          *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
        esac
      done

      parse_machine_selection_args "$@"

      if ! incus info >/dev/null 2>&1; then
        echo "Incus daemon is unavailable; settle cannot continue" >&2
        exit 1
      fi

      instance_metadata_json() {
        local name="$1"

        incus query "$(instance_query_path "$name")" --raw 2>/dev/null \
          | jq -c '.metadata // {}' 2>/dev/null \
          || echo '{}'
      }

      deadline="$(( $(date +%s) + timeout_secs ))"
      while :; do
        pending=0

        while IFS= read -r name; do
          [ -n "$name" ] || continue

          if ! printf '%s' "$declared_instances" | jq -e --arg name "$name" 'index($name) != null' >/dev/null; then
            echo "Skipping undeclared Incus instance: $name" >&2
            continue
          fi

          expected_ip="$(
            printf '%s' "$instance_ipv4_addresses" | jq -r --arg name "$name" '.[$name] // ""'
          )"
          expected_ssh_port="$(
            printf '%s' "$instance_ssh_ports" | jq -r --arg name "$name" '.[$name] // 22'
          )"
          wait_for_ssh="$(
            printf '%s' "$instance_wait_for_ssh" | jq -r --arg name "$name" '.[$name] // true'
          )"
          instance_json="$(instance_metadata_json "$name")"
          status="$(printf '%s' "$instance_json" | jq -r 'if . == {} then "missing" else .status // "unknown" end')"
          instance_state_json='{}'

          if [ "$status" != "Running" ]; then
            pending=1
            echo "Waiting for Incus instance $name to reach Running (current: $status)" >&2
            continue
          fi

          instance_state_json="$(
            incus query "$(instance_query_path "$name")/state" --raw 2>/dev/null \
              | jq -c '.metadata // {}' 2>/dev/null \
              || echo '{}'
          )"

          if ! timeout 10 incus exec "$name" -- true >/dev/null 2>&1; then
            pending=1
            echo "Waiting for Incus instance $name to accept incus exec" >&2
            continue
          fi

          if [ -n "$expected_ip" ] && ! printf '%s' "$instance_state_json" \
            | jq -e --arg ip "$expected_ip" '
              .network // {}
              | to_entries[]
              | select(.key != "lo")
              | .value.addresses[]?
              | select(.family == "inet" and .address == $ip)
            ' >/dev/null 2>&1; then
            pending=1
            echo "Waiting for Incus instance $name to report expected IPv4 ''${expected_ip}" >&2
            continue
          fi

          if [ "$wait_for_ssh" = "true" ] && [ -n "$expected_ip" ] && ! timeout 5 \
            bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "$expected_ip" "$expected_ssh_port" \
            >/dev/null 2>&1; then
            pending=1
            echo "Waiting for Incus instance $name SSH on ''${expected_ip}:''${expected_ssh_port}" >&2
            continue
          fi
        done < <(echo "$selected_json" | jq -r '.[]')

        if [ "$pending" -eq 0 ]; then
          exit 0
        fi

        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Timed out waiting for Incus instance readiness" >&2
          exit 1
        fi

        sleep "$interval_secs"
      done
    '';
  };

  # Per-instance systemd service.
  mkMachineService = name: machine: let
    instanceImage = instanceImages.${name};
    hash = configHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    createOnlyDevSpec = createOnlyDeviceSpecJson machine;
    userMeta = mkUserMetadata name machine;
    escapedName = lib.escapeShellArg name;
    serviceDeps = [
      "incus-preseed.service"
      "network-online.target"
      "incus-images.service"
      "incus-machines-gc.service"
    ];
    setMetaCmds = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "  ${incus} config set ${escapedName} ${k}=${lib.escapeShellArg v}") userMeta
    );
    setConfigCmds = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "  ${incus} config set ${escapedName} ${k}=${lib.escapeShellArg v}") machine.config
    );
  in
    lib.nameValuePair "incus-${name}" {
      description = "Incus container lifecycle for ${name}";
      wantedBy = ["multi-user.target"];
      after = serviceDeps;
      wants = serviceDeps;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "-${incus} stop ${escapedName}";
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
        query_name="$(${pkgs.jq}/bin/jq -nr --arg value ${lib.escapeShellArg name} '$value | @uri')"

        needs_create=0
        needs_recreate=0
        needs_restart=0

        if ! ${incus} info ${escapedName} >/dev/null 2>&1; then
          needs_create=1
        else
          current_config_hash="$(${incus} config get ${escapedName} user.config-hash 2>/dev/null || true)"
          current_recreate_tag="$(${incus} config get ${escapedName} user.recreate-tag 2>/dev/null || true)"
          current_boot_tag="$(${incus} config get ${escapedName} user.boot-tag 2>/dev/null || true)"

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
          ${incus} stop ${escapedName} --force 2>/dev/null || true
          ${incus} delete ${escapedName} --force 2>/dev/null || true
          needs_create=1
        fi

        # Create from base image.
        if [ "$needs_create" -eq 1 ]; then
          echo "Creating ${name} from image ${instanceImage.createRef}..."
          ${incus} create ${lib.escapeShellArg instanceImage.createRef} ${lib.escapeShellArg name}

          # Apply container config.
        ${setConfigCmds}

          # Apply user metadata.
        ${setMetaCmds}

          # Override eth0 IP.
          ${incus} config device override ${escapedName} eth0 ipv4.address=${machine.ipv4Address}

          # Add create-only devices (gpu, unix-char, etc.) — only at creation.
          echo "Adding create-only devices for ${name}..."
          create_only_devices='${createOnlyDevSpec}'
          mapfile -t create_only_device_names < <(json_keys "$create_only_devices")
          if [ "''${#create_only_device_names[@]}" -gt 0 ]; then
            for dev in "''${create_only_device_names[@]}"; do
              props="$(printf '%s' "$create_only_devices" | jq -c --arg d "$dev" '.[$d]')"
              echo "  Adding device $dev ($(printf '%s' "$props" | jq -r '.type'))"
              add_device_from_props ${escapedName} "$dev" "$props"
            done
          fi
        fi

        current_devices="$(${incus} query "/1.0/instances/$query_name" --raw 2>/dev/null | \
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
        if [ "''${#current_disk_names[@]}" -gt 0 ]; then
          for dev in "''${current_disk_names[@]}"; do
            if ! printf '%s' "$desired_disks" | jq -e --arg d "$dev" 'has($d)' >/dev/null 2>&1; then
              echo "  Removing disk device $dev"
              ${incus} config device remove ${escapedName} "$dev" 2>/dev/null || true
            fi
          done
        fi

        # Add or update disk devices.
        mapfile -t desired_disk_names < <(json_keys "$desired_disks")
        if [ "''${#desired_disk_names[@]}" -gt 0 ]; then
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
              add_device_from_props ${escapedName} "$dev" "$desired_props"
            else
              # Remove stale properties first so disk devices stay declarative.
              mapfile -t current_prop_keys < <(json_property_keys "$current_props")
              if [ "''${#current_prop_keys[@]}" -gt 0 ]; then
                for key in "''${current_prop_keys[@]}"; do
                  if ! printf '%s' "$desired_props" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
                    ${incus} config device unset ${escapedName} "$dev" "$key"
                  fi
                done
              fi

              # Device exists, update changed properties.
              mapfile -t desired_prop_keys < <(json_property_keys "$desired_props")
              if [ "''${#desired_prop_keys[@]}" -gt 0 ]; then
                for key in "''${desired_prop_keys[@]}"; do
                  desired_val="$(printf '%s' "$desired_props" | jq -r --arg k "$key" '.[$k]')"
                  ${incus} config device set ${escapedName} "$dev" "$key" "$desired_val"
                done
              fi
            fi
          done
        fi

        # Update IP address (always sync).
        ${incus} config device set ${escapedName} eth0 ipv4.address=${machine.ipv4Address} 2>/dev/null || \
          ${incus} config device override ${escapedName} eth0 ipv4.address=${machine.ipv4Address} 2>/dev/null || true

        # Update metadata.
        ${incus} config set ${escapedName} user.config-hash=${lib.escapeShellArg hash}
        ${incus} config set ${escapedName} user.boot-tag=${lib.escapeShellArg machine.bootTag}
        ${incus} config set ${escapedName} user.recreate-tag=${lib.escapeShellArg machine.recreateTag}

        # Restart if boot tag changed (and we didn't already recreate).
        if [ "$needs_restart" -eq 1 ]; then
          echo "Restarting ${name} (boot tag changed)..."
          ${incus} stop ${escapedName} --force 2>/dev/null || true
        fi

        current_status="$(${incus} query "/1.0/instances/$query_name" --raw 2>/dev/null | \
          jq -r '.metadata.status // "unknown"' 2>/dev/null || printf 'missing\n')"

        # Start the container when it is not already running. Real start
        # failures must fail the unit instead of being masked as success.
        if [ "$current_status" != "Running" ]; then
          ${incus} start ${escapedName}
        fi
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
    defaultImage = lib.mkOption {
      type = lib.types.raw;
      default = defaultBaseImage;
      description = ''
        Default image source used for Incus machines when a machine does not
        set `image`. A string is treated as an Incus image reference; a
        non-string value is treated as a local NixOS image build.
      '';
    };

    defaultImageAlias = lib.mkOption {
      type = lib.types.str;
      default = defaultBaseAlias;
      description = ''
        Shared Incus alias used for `defaultImage`. Machines that set a custom
        `image` default to `nixos-incus-<machine-name>` for local NixOS images
        and a sanitized alias derived from the remote image reference for string
        images unless they also set `imageAlias`.
      '';
    };

    imageTag = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = "Bump to force refresh of all declared Incus images on next rebuild.";
    };

    reconcilePolicy = lib.mkOption {
      type = lib.types.enum ["off" "best-effort" "strict"];
      default = "best-effort";
      description = ''
        Reconcile policy for declared Incus guests. `off` disables guest
        reconcile helpers, `best-effort` retries missing or stopped guests
        without failing the caller, and `strict` makes guest reconcile failures
        abort the caller.
      '';
    };

    autoReconcile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to run guest reconcile automatically at boot via
        `incus-machines-reconciler.service`. This is disabled by default so
        host activation and boot do not depend on child guest lifecycle
        convergence.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf machineType;
      default = {};
      description = "Declarative Incus containers with lifecycle management.";
    };
  };

  config = lib.mkIf hasInstances {
    assertions = [
      {
        assertion = imageAliasConflicts == [];
        message =
          "services.incusMachines has conflicting image aliases with different image sources: "
          + lib.concatStringsSep ", " imageAliasConflicts;
      }
      {
        assertion = ipv4AddressConflicts == [];
        message =
          "services.incusMachines has duplicate ipv4Address assignments: "
          + lib.concatStringsSep "; " ipv4AddressConflicts;
      }
    ];

    virtualisation.incus = {
      enable = lib.mkDefault true;
      package = lib.mkDefault pkgs.incus;
      ui.enable = lib.mkDefault true;
    };

    systemd.tmpfiles.rules =
      lib.concatLists (lib.mapAttrsToList mkDeviceTmpfiles cfg.instances);

    environment.systemPackages = [
      reconcilerHelper
      settlementHelper
    ];

    systemd.services = let
      incusLifecycleDeps = [
        "incus-preseed.service"
        "network-online.target"
        "incus-images.service"
        "incus-machines-gc.service"
      ];
      incusGcDeps = [
        "incus-preseed.service"
        "incus-images.service"
      ];
    in
      {
        incus-machines-reconciler = lib.mkIf (cfg.reconcilePolicy != "off") {
          description = "Reconciler for declared Incus guests";
          wantedBy = lib.optional cfg.autoReconcile "multi-user.target";
          after = incusLifecycleDeps;
          wants = incusLifecycleDeps;
          serviceConfig = {
            Type = "oneshot";
          };
          script = ''
            exec ${reconcilerHelper}/bin/incus-machines-reconciler --all
          '';
        };

        incus-images = {
          description = "Import/update declared Incus images";
          wantedBy = ["multi-user.target"];
          after = ["incus-preseed.service"];
          wants = ["incus-preseed.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [config.virtualisation.incus.package.client pkgs.coreutils];
          script = ''
            set -euo pipefail

            desired_rebuild_tag=${lib.escapeShellArg cfg.imageTag}
            declared_images='${declaredImagesJson}'

            echo "$declared_images" | ${pkgs.jq}/bin/jq -c '.[]' | while IFS= read -r image; do
              alias="$(printf '%s' "$image" | ${pkgs.jq}/bin/jq -r '.alias')"
              image_kind="$(printf '%s' "$image" | ${pkgs.jq}/bin/jq -r '.kind')"
              image_identity="$(printf '%s' "$image" | ${pkgs.jq}/bin/jq -r '.imageIdentity')"

              current_source="$(${incus} image get-property "local:$alias" user.base-image-id 2>/dev/null || true)"
              current_rebuild_tag="$(${incus} image get-property "local:$alias" user.base-image-rebuild-tag 2>/dev/null || true)"

              if [ "$current_source" = "$image_identity" ] && \
                 [ "$current_rebuild_tag" = "$desired_rebuild_tag" ] && \
                 ${incus} image info "local:$alias" >/dev/null 2>&1; then
                continue
              fi

              if ${incus} image info "local:$alias" >/dev/null 2>&1; then
                ${incus} image delete "local:$alias"
              fi

              case "$image_kind" in
                local)
                  metadata_file="$(printf '%s' "$image" | ${pkgs.jq}/bin/jq -r '.metadataFile')"
                  rootfs_file="$(printf '%s' "$image" | ${pkgs.jq}/bin/jq -r '.rootfsFile')"

                  if [ ! -f "$metadata_file" ] || [ ! -f "$rootfs_file" ]; then
                    echo "Missing base image tarballs for $alias:" >&2
                    echo "  $metadata_file" >&2
                    echo "  $rootfs_file" >&2
                    exit 1
                  fi

                  # Incus identifies split images by the SHA-256 of the
                  # metadata/rootfs file concatenation. If the exact same image
                  # already exists under another alias, reuse that fingerprint
                  # instead of failing the import with "same fingerprint already
                  # exists".
                  image_fingerprint="$(${pkgs.coreutils}/bin/cat "$metadata_file" "$rootfs_file" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.gawk}/bin/awk '{print $1}')"

                  if ${incus} image info "local:$image_fingerprint" >/dev/null 2>&1; then
                    ${incus} image alias create "local:$alias" "$image_fingerprint"
                  else
                    ${incus} image import "$metadata_file" "$rootfs_file" --alias "$alias"
                  fi
                  ;;
                remote)
                  remote_ref="$(printf '%s' "$image" | ${pkgs.jq}/bin/jq -r '.remoteRef')"
                  ${incus} image copy "$remote_ref" local: --alias "$alias"
                  ;;
                *)
                  echo "Unknown image kind for $alias: $image_kind" >&2
                  exit 1
                  ;;
              esac

              ${incus} image set-property "local:$alias" user.base-image-id "$image_identity"
              ${incus} image set-property "local:$alias" user.base-image-rebuild-tag "$desired_rebuild_tag"
            done
          '';
        };

        incus-machines-gc = {
          description = "Garbage-collect Incus containers no longer declared in NixOS config";
          wantedBy = ["multi-user.target"];
          after = incusGcDeps;
          wants = incusGcDeps;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [config.virtualisation.incus.package.client pkgs.jq];
          script = ''
            set -euo pipefail

            declared_instances='${declaredInstancesJson}'

            # List all containers managed by us.
            if ! all_containers="$(${incus} list --format json 2>/dev/null)"; then
              echo "Failed to list Incus containers for garbage collection" >&2
              exit 1
            fi

            echo "$all_containers" | jq -c '.[]' | while IFS= read -r row; do
              cname="$(echo "$row" | jq -r '.name')"
              managed="$(echo "$row" | jq -r '.config["user.managed-by"] // ""')"

              [ "$managed" = "nixos" ] || continue

              # Check if still declared.
              if echo "$declared_instances" | jq -e --arg n "$cname" 'index($n) != null' >/dev/null 2>&1; then
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
                      | $cfg
                      | to_entries[]
                      | select(.key | test("^user\\.device\\..+\\.removal-policy$"))
                      | select(.value == "delete")
                      | (.key | capture("^user\\.device\\.(?<name>.*)\\.removal-policy$").name) as $name
                      | $cfg["user.device.\($name).source"] // empty
                    '
                  )

                  ${incus} delete "$cname" --force 2>/dev/null || true

                  if [ "''${#dirs_to_remove[@]}" -gt 0 ]; then
                    for dir in "''${dirs_to_remove[@]}"; do
                      [ -d "$dir" ] || continue
                      echo "  Removing source dir: $dir"
                      rm -rf "$dir"
                    done
                  fi
                  ;;
              esac
            done
          '';
        };
      }
      // lib.mapAttrs' mkMachineService cfg.instances;
  };
}

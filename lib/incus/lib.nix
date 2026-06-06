{
  lib,
  config ? null,
}: let
  defaultVideoGid =
    if config == null
    then null
    else config.users.groups.video.gid;
  defaultRenderGid =
    if config == null
    then null
    else config.users.groups.render.gid;

  mkUnixCharDevice = {
    source,
    path ? source,
    gid ? null,
    extraProperties ? {},
  }: {
    type = "unix-char";
    source = source;
    path = path;
    extraProperties =
      lib.optionalAttrs (gid != null) {
        gid = toString gid;
      }
      // extraProperties;
  };

  mkGpuDevices = {
    card ? null,
    render ? null,
    kfd ? false,
    videoGid ? defaultVideoGid,
    renderGid ? defaultRenderGid,
    cardName ?
      if card == null
      then null
      else "dev-dri-card-${toString card}",
    renderName ?
      if render == null
      then null
      else "dev-dri-render-${toString render}",
    kfdName ? "kfd",
  }:
    lib.optionalAttrs (card != null) {
      ${cardName} = mkUnixCharDevice {
        source = "/dev/dri/card${toString card}";
        gid = videoGid;
      };
    }
    // lib.optionalAttrs (render != null) {
      ${renderName} = mkUnixCharDevice {
        source = "/dev/dri/renderD${toString render}";
        gid = renderGid;
      };
    }
    // lib.optionalAttrs kfd {
      ${kfdName} = mkUnixCharDevice {
        source = "/dev/kfd";
        gid = renderGid;
      };
    };

  mkIncusProxy = {
    connectHost,
    listenHost ? "127.0.0.1",
    listenPort ? 8443,
    connectPort ? listenPort,
    bind ? "instance",
    extraProperties ? {},
  }: {
    type = "proxy";
    extraProperties =
      {
        inherit bind;
        listen = "tcp:${listenHost}:${toString listenPort}";
        connect = "tcp:${connectHost}:${toString connectPort}";
      }
      // extraProperties;
  };

  mkCertDelegation = name: {
    type = "disk";
    certDelegation = name;
  };

  mkLxc = {
    name,
    ipv4Address,
    image ? null,
    removalPolicy ? null,
    adopt ? null,
    recreateTag ? null,
    privileged ? false,
    nestedContainers ? false,
    interceptMounts ? false,
    interceptMountShift ? true,
    extraConfig ? {},
    extraDevices ? {},
  }:
    {
      name = name;
      ipv4Address = ipv4Address;
      config =
        {
          "security.privileged" =
            if privileged
            then "true"
            else "false";
        }
        // lib.optionalAttrs nestedContainers {
          "security.nesting" = "true";
        }
        // lib.optionalAttrs interceptMounts {
          "security.syscalls.intercept.mount" = "true";
        }
        // lib.optionalAttrs (interceptMounts && interceptMountShift) {
          "security.syscalls.intercept.mount.shift" = "true";
        }
        // extraConfig;
      devices =
        {
          state = {
            source = name;
            path = "/var/lib";
            removalPolicy = "keep";
          };
        }
        // extraDevices;
    }
    // lib.optionalAttrs (image != null) {
      image = image;
    }
    // lib.optionalAttrs (removalPolicy != null) {
      removalPolicy = removalPolicy;
    }
    // lib.optionalAttrs (adopt != null) {
      adopt = adopt;
    }
    // lib.optionalAttrs (recreateTag != null) {
      recreateTag = recreateTag;
    };

  fabricPolicyProfiles = rec {
    open = {
      forwardTo = true;
      allowFromHost = true;
      allowToHost = true;
      allowToUplink = true;
      allowFromUplink = true;
    };
    isolated = {
      forwardTo = false;
      allowFromHost = false;
      allowToHost = false;
      allowToUplink = true;
      allowFromUplink = false;
    };
    isolatedPublic =
      isolated
      // {
        allowFromUplink = true;
      };
    contained =
      isolated
      // {
        allowFromHost = true;
      };
    containedPublic =
      contained
      // {
        allowFromUplink = true;
      };
    quarantine =
      isolated
      // {
        allowToUplink = false;
      };
  };

  mkManagedFabricPolicy = {
    defaultInterface ? "incusbr0",
    defaultPolicy ? fabricPolicyProfiles.open,
    projects,
    tableName ? "incusManagedFabricPolicy",
  }: let
    managedFabricInterfaces =
      {
        default = defaultInterface;
      }
      // lib.mapAttrs (_project: project: project.network.name) projects;
    managedFabricNames = builtins.attrNames managedFabricInterfaces;

    managedFabricInterfaceSet = lib.concatStringsSep ", " (
      lib.mapAttrsToList (_name: iface: "\"${iface}\"") managedFabricInterfaces
    );

    normalizeForwardTo = source: forwardTo:
      if builtins.isList forwardTo
      then forwardTo
      else if builtins.isBool forwardTo && forwardTo
      then lib.remove source managedFabricNames
      else [];

    normalizePolicy = source: policy: {
      forwardTo = normalizeForwardTo source (policy.forwardTo or false);
      allowFromHost = policy.allowFromHost or false;
      allowToHost = policy.allowToHost or false;
      allowToUplink = policy.allowToUplink or false;
      allowFromUplink = policy.allowFromUplink or false;
    };

    fabricPolicy = source:
      normalizePolicy source (
        if source == "default"
        then defaultPolicy
        else projects.${source}.network.policy or {}
      );

    invalidFabricPolicyModes =
      lib.filter
      (
        source: let
          rawPolicy =
            if source == "default"
            then defaultPolicy
            else projects.${source}.network.policy or {};
        in
          !(
            builtins.isAttrs rawPolicy
            && builtins.isBool (rawPolicy.allowFromHost or false)
            && builtins.isBool (rawPolicy.allowToHost or false)
            && builtins.isBool (rawPolicy.allowToUplink or false)
            && builtins.isBool (rawPolicy.allowFromUplink or false)
            && (builtins.isBool (rawPolicy.forwardTo or false) || builtins.isList (rawPolicy.forwardTo or false))
          )
      )
      managedFabricNames;

    invalidFabricPolicyTargets =
      lib.concatMap (
        source:
          lib.map
          (target: "${source} -> ${target}")
          (
            lib.filter
            (target: !builtins.elem target managedFabricNames)
            (
              if builtins.elem source invalidFabricPolicyModes
              then []
              else (fabricPolicy source).forwardTo
            )
          )
      )
      managedFabricNames;

    forwardToDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source: let
          deniedTargets =
            lib.filter
            (target: target != source && !builtins.elem target (fabricPolicy source).forwardTo)
            managedFabricNames;
        in
          lib.map
          (
            target: ''iifname "${managedFabricInterfaces.${source}}" oifname "${managedFabricInterfaces.${target}}" drop comment "deny ${source} -> ${target}"''
          )
          deniedTargets
      )
      managedFabricNames
    );

    hostToFabricDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optional (!(fabricPolicy source).allowFromHost)
          ''oifname "${managedFabricInterfaces.${source}}" ct state { new, untracked } drop comment "deny host -> ${source}"''
      )
      managedFabricNames
    );

    fabricToHostDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optional (!(fabricPolicy source).allowToHost)
          ''iifname "${managedFabricInterfaces.${source}}" ct state { new, untracked } drop comment "deny ${source} -> host"''
      )
      managedFabricNames
    );

    fabricToUplinkDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optional (!(fabricPolicy source).allowToUplink)
          ''iifname "${managedFabricInterfaces.${source}}" oifname != { ${managedFabricInterfaceSet} } drop comment "deny ${source} -> uplink"''
      )
      managedFabricNames
    );

    uplinkToFabricDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optional (!(fabricPolicy source).allowFromUplink)
          ''iifname != { ${managedFabricInterfaceSet} } oifname "${managedFabricInterfaces.${source}}" ct state { new, untracked } drop comment "deny uplink -> ${source}"''
      )
      managedFabricNames
    );

    trustedInterfaces =
      lib.filter
      (iface: iface != null)
      (
        lib.map
        (
          source:
            if (fabricPolicy source).allowToHost
            then managedFabricInterfaces.${source}
            else null
        )
        managedFabricNames
      );
  in {
    inherit managedFabricInterfaces managedFabricNames trustedInterfaces;
    assertions = [
      {
        assertion = invalidFabricPolicyModes == [];
        message =
          "Incus managed fabric policies must be attrsets with boolean host/uplink flags and forwardTo as bool or list: "
          + lib.concatStringsSep ", " invalidFabricPolicyModes;
      }
      {
        assertion = invalidFabricPolicyTargets == [];
        message =
          "Incus managed fabric policy forwardTo targets must reference managed fabrics only: "
          + lib.concatStringsSep ", " invalidFabricPolicyTargets;
      }
    ];
    nftablesTable = {
      ${tableName} = {
        family = "inet";
        content = ''
          chain input {
            type filter hook input priority -5; policy accept;

            ct state { established, related } accept
            ct state invalid drop

            ${fabricToHostDropRules}
          }

          chain output {
            type filter hook output priority -5; policy accept;

            ct state { established, related } accept
            ct state invalid drop

            ${hostToFabricDropRules}
          }

          chain forward {
            type filter hook forward priority -5; policy accept;

            ct state { established, related } accept
            ct state invalid drop

            ${forwardToDropRules}
            ${fabricToUplinkDropRules}
            ${uplinkToFabricDropRules}
          }
        '';
      };
    };
  };

  certsForUsers = users: import ./certs.nix {users = users;};

  mkUserCertsForProjects = {
    users,
    root,
    projects,
    certPath,
    keyPath,
    pfxPath,
    extraKeyRecipients ? [],
    keyType ? "ecdsa-p256",
    days ? 3650,
  }: let
    certs = certsForUsers users;
  in
    certs.mkUserCertsForProjects {
      root = root;
      projects = projects;
      mkUserCert = {
        user,
        projects,
      }:
        certs.mkUserCertWithKeys {
          inherit days keyType projects user;
          cert = certPath user;
          inherit extraKeyRecipients;
          key = keyPath user;
          pfx = pfxPath user;
        };
    };
in {
  inherit certsForUsers fabricPolicyProfiles mkCertDelegation mkGpuDevices mkIncusProxy mkLxc mkManagedFabricPolicy mkUserCertsForProjects;
  certs = import ./certs.nix;
}

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
          "security.syscalls.intercept.mknod" = "true";
          "security.syscalls.intercept.setxattr" = "true";
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
        // lib.optionalAttrs nestedContainers {
          fuse = mkUnixCharDevice {
            source = "/dev/fuse";
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

  allowToHostProfiles = {
    default = {
      dhcpv4 = true;
      dhcpv6 = true;
      dns = true;
    };
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
      allowToHost = allowToHostProfiles.default;
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
        allowToHost = false;
        allowToUplink = false;
      };
  };

  mkManagedFabricPolicy = {
    defaultInterface ? "incusbr0",
    defaultPolicy ? fabricPolicyProfiles.open,
    forwardRules ? [],
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

    normalizeAllowToHost = allowToHost:
      if builtins.isBool allowToHost
      then {
        all = allowToHost;
        services = {};
      }
      else {
        all = false;
        services = {
          dhcpv4 = allowToHost.dhcpv4 or false;
          dhcpv6 = allowToHost.dhcpv6 or false;
          dns = allowToHost.dns or false;
        };
      };

    normalizePolicy = source: policy: {
      forwardTo = normalizeForwardTo source (policy.forwardTo or false);
      allowFromHost = policy.allowFromHost or false;
      allowToHost = normalizeAllowToHost (policy.allowToHost or false);
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
          rawAllowToHost = rawPolicy.allowToHost or false;
          validAllowToHost =
            if builtins.isBool rawAllowToHost
            then true
            else if builtins.isAttrs rawAllowToHost
            then
              lib.all
              (name: builtins.elem name ["dhcpv4" "dhcpv6" "dns"])
              (builtins.attrNames rawAllowToHost)
              && lib.all builtins.isBool (builtins.attrValues rawAllowToHost)
            else false;
        in
          !(
            builtins.isAttrs rawPolicy
            && builtins.isBool (rawPolicy.allowFromHost or false)
            && validAllowToHost
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

    validPort = port: builtins.isInt port && port > 0 && port < 65536;
    validPortList = ports: builtins.isList ports && lib.all validPort ports;

    validForwardRule = rule:
      builtins.isAttrs rule
      && builtins.isString (rule.from or null)
      && builtins.isString (rule.to or null)
      && builtins.elem rule.from managedFabricNames
      && builtins.elem rule.to managedFabricNames
      && (
        !(rule ? source)
        || builtins.isString rule.source
      )
      && (
        !(rule ? destination)
        || builtins.isString rule.destination
      )
      && validPortList (rule.tcpPorts or [])
      && validPortList (rule.udpPorts or [])
      && ((rule.tcpPorts or []) != [] || (rule.udpPorts or []) != []);

    invalidForwardRules = lib.filter (rule: !validForwardRule rule) forwardRules;
    validForwardRules = lib.filter validForwardRule forwardRules;

    describeForwardRule = rule:
      if builtins.isAttrs rule
      then "${rule.from or "<missing>"} -> ${rule.to or "<missing>"}"
      else builtins.toJSON rule;

    renderPortSet = ports:
      if builtins.length ports == 1
      then builtins.toString (builtins.head ports)
      else "{ ${lib.concatMapStringsSep ", " builtins.toString ports} }";

    renderForwardRule = rule: protocol: ports: let
      sourceMatch = lib.optionalString (rule ? source) " ip saddr ${rule.source}";
      destinationMatch = lib.optionalString (rule ? destination) " ip daddr ${rule.destination}";
    in ''
      iifname "${managedFabricInterfaces.${rule.from}}" oifname "${managedFabricInterfaces.${rule.to}}"${sourceMatch}${destinationMatch} ${protocol} dport ${renderPortSet ports} accept comment "allow ${rule.from} -> ${rule.to}"
    '';

    forwardRuleset = builtins.concatStringsSep "\n" (
      lib.concatMap (
        rule:
          lib.optionals ((rule.tcpPorts or []) != []) [
            (renderForwardRule rule "tcp" rule.tcpPorts)
          ]
          ++ lib.optionals ((rule.udpPorts or []) != []) [
            (renderForwardRule rule "udp" rule.udpPorts)
          ]
      )
      validForwardRules
    );

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

    fabricToHostServiceRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source: let
          services = (fabricPolicy source).allowToHost.services;
          iface = managedFabricInterfaces.${source};
        in
          lib.optionals (services.dhcpv4 or false) [
            ''iifname "${iface}" udp sport 68 udp dport 67 accept comment "allow ${source} -> host dhcpv4"''
          ]
          ++ lib.optionals (services.dhcpv6 or false) [
            ''iifname "${iface}" meta nfproto ipv6 udp sport 546 udp dport 547 accept comment "allow ${source} -> host dhcpv6"''
          ]
          ++ lib.optionals (services.dns or false) [
            ''iifname "${iface}" udp dport 53 accept comment "allow ${source} -> host dns udp"''
            ''iifname "${iface}" tcp dport 53 accept comment "allow ${source} -> host dns tcp"''
          ]
      )
      managedFabricNames
    );

    fabricToHostDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optional (!(fabricPolicy source).allowToHost.all)
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
            if (fabricPolicy source).allowToHost.all
            then managedFabricInterfaces.${source}
            else null
        )
        managedFabricNames
      );

    firewallInterfaces = lib.listToAttrs (
      lib.filter
      (entry: entry.value != {})
      (
        lib.map (
          source: let
            allowToHost = (fabricPolicy source).allowToHost;
            services = allowToHost.services;
            udpPorts =
              lib.optionals (services.dhcpv4 or false) [67]
              ++ lib.optionals (services.dhcpv6 or false) [547]
              ++ lib.optionals (services.dns or false) [53];
            tcpPorts = lib.optionals (services.dns or false) [53];
          in {
            name = managedFabricInterfaces.${source};
            value =
              lib.optionalAttrs (!allowToHost.all && udpPorts != []) {
                allowedUDPPorts = udpPorts;
              }
              // lib.optionalAttrs (!allowToHost.all && tcpPorts != []) {
                allowedTCPPorts = tcpPorts;
              };
          }
        )
        managedFabricNames
      )
    );
  in {
    inherit firewallInterfaces managedFabricInterfaces managedFabricNames trustedInterfaces;
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
      {
        assertion = invalidForwardRules == [];
        message =
          "Incus managed fabric policy forwardRules must reference managed fabrics and include tcpPorts or udpPorts: "
          + lib.concatMapStringsSep ", " describeForwardRule invalidForwardRules;
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

            ${fabricToHostServiceRules}
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

            ${forwardRuleset}
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
  inherit allowToHostProfiles certsForUsers fabricPolicyProfiles mkCertDelegation mkGpuDevices mkIncusProxy mkLxc mkManagedFabricPolicy mkUserCertsForProjects;
  certs = import ./certs.nix;
}

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
    ipv4Address ? null,
    network ? null,
    image ? null,
    startPriority ? null,
    removalPolicy ? null,
    adopt ? null,
    recreateTag ? null,
    privileged ? false,
    nestedContainers ? false,
    interceptMounts ? false,
    interceptMountShift ? true,
    stateVolumeSize ? null,
    limits ? {},
    extraConfig ? {},
    extraDevices ? {},
  }:
    {
      name = name;
      limits = limits;
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
            extraProperties = lib.optionalAttrs (stateVolumeSize != null) {
              size = stateVolumeSize;
            };
          };
        }
        // lib.optionalAttrs nestedContainers {
          fuse = mkUnixCharDevice {
            source = "/dev/fuse";
          };
        }
        // extraDevices;
    }
    // lib.optionalAttrs (ipv4Address != null) {
      ipv4Address = ipv4Address;
    }
    // lib.optionalAttrs (network != null) {
      network = network;
    }
    // lib.optionalAttrs (image != null) {
      image = image;
    }
    // lib.optionalAttrs (startPriority != null) {
      startPriority = startPriority;
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
    defaultFabric ? {},
    defaultInterface ? "incusbr0",
    defaultPolicy ? fabricPolicyProfiles.open,
    enabledFamilies ? ["ipv4" "ipv6"],
    forwardRules ? [],
    projects,
    routedFabrics ? {},
    sourcePreservingPrefixes ? {},
    tableName ? "incusManagedFabricPolicy",
  }: let
    defaultFabricDefinition = {
      interface = defaultInterface;
      policy = defaultPolicy;
      subnets = defaultFabric.subnets or {};
      masqueradeToUplink = defaultFabric.masqueradeToUplink or {};
    };
    projectFabricDefinitions =
      lib.mapAttrs (_project: project: {
        interface = project.network.name;
        policy = project.network.policy or {};
        subnets = project.network.subnets or {};
        masqueradeToUplink = project.network.masqueradeToUplink or {};
      })
      projects;
    interfaceFabricDefinitions = {default = defaultFabricDefinition;} // projectFabricDefinitions;
    interfaceFabricInterfaces =
      lib.mapAttrs (_name: fabric: fabric.interface) interfaceFabricDefinitions;
    interfaceFabricNames = builtins.attrNames interfaceFabricInterfaces;
    routedFabricNames = builtins.attrNames routedFabrics;
    duplicateRoutedFabricNames = lib.intersectLists interfaceFabricNames routedFabricNames;
    routedParent = name: let
      routed = routedFabrics.${name};
    in
      if builtins.isAttrs routed
      then routed.parent or null
      else null;
    invalidRoutedFabricParents =
      lib.filter
      (
        name: let
          parent = routedParent name;
        in
          !builtins.isString parent || !builtins.hasAttr parent interfaceFabricInterfaces
      )
      routedFabricNames;
    routedFabricInterfaces =
      lib.mapAttrs (
        _name: routed: let
          parent =
            if builtins.isAttrs routed
            then routed.parent or "default"
            else "default";
        in
          interfaceFabricInterfaces.${parent} or defaultInterface
      )
      routedFabrics;
    managedFabricInterfaces = interfaceFabricInterfaces // routedFabricInterfaces;
    managedFabricNames = builtins.attrNames managedFabricInterfaces;
    managedPhysicalInterfaces = lib.unique (builtins.attrValues interfaceFabricInterfaces);
    duplicatePhysicalInterfaces =
      lib.filter
      (iface:
        builtins.length (
          lib.filter (candidate: candidate == iface) (builtins.attrValues interfaceFabricInterfaces)
        )
        > 1)
      managedPhysicalInterfaces;

    addressFamilies = ["ipv4" "ipv6"];
    nftFamily = {
      ipv4 = "ip";
      ipv6 = "ip6";
    };
    addressFamily = address:
      if lib.hasInfix ":" address
      then "ipv6"
      else "ipv4";
    decimalWithin = maximum: value: let
      parsed = builtins.tryEval (lib.toInt value);
    in
      builtins.match "[0-9]+" value
      != null
      && parsed.success
      && parsed.value <= maximum;
    addressParts = address: lib.splitString "/" address;
    validIpv4Address = address: let
      octets = lib.splitString "." address;
    in
      builtins.length octets
      == 4
      && lib.all (decimalWithin 255) octets;
    validIpv6Address = address:
      (builtins.tryEval (lib.network.ipv6.fromString address)).success;
    validAddressForFamily = family: address: let
      parts = addressParts address;
      addressValue = builtins.head parts;
      validAddress =
        if family == "ipv4"
        then validIpv4Address addressValue
        else validIpv6Address addressValue;
      validPrefix =
        builtins.length parts
        == 1
        || (
          builtins.length parts
          == 2
          && decimalWithin
          (
            if family == "ipv4"
            then 32
            else 128
          )
          (builtins.elemAt parts 1)
        );
    in
      validAddress && validPrefix;
    validSubnetForFamily = family: subnet:
      builtins.length (addressParts subnet)
      == 2
      && validAddressForFamily family subnet;
    routedSubnets = name: let
      routed = routedFabrics.${name};
      subnets =
        if builtins.isAttrs routed
        then routed.subnets or {}
        else {};
    in
      if builtins.isAttrs subnets
      then subnets
      else {};
    interfaceSubnets = name: interfaceFabricDefinitions.${name}.subnets;
    fabricSubnets = name:
      if builtins.hasAttr name routedFabrics
      then routedSubnets name
      else interfaceSubnets name;
    routedAddressFamilies = name:
      lib.filter
      (family: builtins.hasAttr family (routedSubnets name))
      enabledFamilies;

    managedFabricInterfaceSet = lib.concatStringsSep ", " (
      map (iface: "\"${iface}\"") managedPhysicalInterfaces
    );

    routedChildrenFor = parent:
      lib.filter
      (name: routedParent name == parent)
      routedFabricNames;
    childSubnetsFor = parent: family:
      map
      (name: (routedSubnets name).${family})
      (lib.filter
        (name: builtins.hasAttr family (routedSubnets name))
        (routedChildrenFor parent));
    renderAddressSet = values:
      if builtins.length values == 1
      then builtins.head values
      else "{ ${lib.concatStringsSep ", " values} }";
    residualSelectorVariants = direction: fabric: let
      childFamilies = lib.filter (family: childSubnetsFor fabric family != []) addressFamilies;
      families =
        if childFamilies == []
        then []
        else enabledFamilies;
    in
      if families == []
      then [
        {
          family = null;
          expression = ''${direction}ifname "${managedFabricInterfaces.${fabric}}"'';
        }
      ]
      else
        map
        (family: let
          exclusions = childSubnetsFor fabric family;
          addressSelector =
            if direction == "i"
            then "saddr"
            else "daddr";
        in {
          inherit family;
          expression =
            ''${direction}ifname "${managedFabricInterfaces.${fabric}}" meta nfproto ${family}''
            + lib.optionalString (exclusions != [])
            " ${nftFamily.${family}} ${addressSelector} != ${renderAddressSet exclusions}";
        })
        families;

    selectorVariants = direction: fabric:
      if builtins.hasAttr fabric routedFabrics
      then
        map
        (family: {
          inherit family;
          expression = ''${direction}ifname "${managedFabricInterfaces.${fabric}}" ${nftFamily.${family}} ${
              if direction == "i"
              then "saddr"
              else "daddr"
            } ${(routedSubnets fabric).${family}}'';
        })
        (routedAddressFamilies fabric)
      else residualSelectorVariants direction fabric;

    compatibleFamilies = left: right:
      left == null || right == null || left == right;

    pairedSelectorVariants = source: target:
      lib.concatMap
      (
        sourceVariant:
          map
          (targetVariant: {
            family =
              if sourceVariant.family != null
              then sourceVariant.family
              else targetVariant.family;
            expression = "${sourceVariant.expression} ${targetVariant.expression}";
          })
          (lib.filter
            (targetVariant: compatibleFamilies sourceVariant.family targetVariant.family)
            (selectorVariants "o" target))
      )
      (selectorVariants "i" source);

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

    rawFabricPolicy = source:
      if builtins.hasAttr source routedFabrics
      then
        if builtins.isAttrs routedFabrics.${source}
        then routedFabrics.${source}.policy or {}
        else {}
      else interfaceFabricDefinitions.${source}.policy;

    fabricPolicy = source:
      normalizePolicy source (
        rawFabricPolicy source
      );

    invalidFabricPolicyModes =
      lib.filter
      (
        source: let
          rawPolicy = rawFabricPolicy source;
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

    invalidFamilyDefinition = {
      masquerade,
      requireSubnets ? false,
      subnets,
    }:
      !builtins.isAttrs subnets
      || (requireSubnets && builtins.attrNames subnets == [])
      || lib.any (family: !builtins.elem family addressFamilies) (builtins.attrNames subnets)
      || lib.any
      (family:
        !builtins.isString subnets.${family}
        || addressFamily subnets.${family} != family
        || !validSubnetForFamily family subnets.${family})
      (builtins.attrNames subnets)
      || !builtins.isAttrs masquerade
      || lib.any (family: !builtins.elem family addressFamilies) (builtins.attrNames masquerade)
      || lib.any
      (family:
        !builtins.isBool masquerade.${family}
        || (masquerade.${family} && !builtins.hasAttr family subnets))
      (builtins.attrNames masquerade);
    invalidInterfaceFabricDefinitions =
      lib.filter
      (name:
        invalidFamilyDefinition {
          subnets = interfaceFabricDefinitions.${name}.subnets;
          masquerade = interfaceFabricDefinitions.${name}.masqueradeToUplink;
        })
      interfaceFabricNames;
    invalidEnabledFamilies =
      enabledFamilies
      == []
      || lib.unique enabledFamilies != enabledFamilies
      || lib.any (family: !builtins.elem family addressFamilies) enabledFamilies;
    incompleteFabricFamilies =
      lib.filter
      (name:
        lib.any
        (family: !builtins.hasAttr family (fabricSubnets name))
        enabledFamilies)
      managedFabricNames;
    fabricPrefixEntries =
      lib.concatMap (
        family:
          lib.concatMap (
            name: let
              subnets = fabricSubnets name;
              subnet =
                if builtins.isAttrs subnets
                then subnets.${family} or null
                else null;
            in
              lib.optional
              (
                builtins.isString subnet
                && addressFamily subnet == family
                && validSubnetForFamily family subnet
              ) {
                inherit family name;
                subnet = subnet;
              }
          )
          managedFabricNames
      )
      enabledFamilies;
    pow2 = exponent:
      if exponent == 0
      then 1
      else 2 * pow2 (exponent - 1);
    parsedNetwork = entry: let
      parsed =
        if entry.family == "ipv4"
        then {
          address = builtins.head (addressParts entry.subnet);
          prefixLength = lib.toInt (builtins.elemAt (addressParts entry.subnet) 1);
        }
        else lib.network.ipv6.fromString entry.subnet;
      partWidth =
        if entry.family == "ipv4"
        then 8
        else 16;
    in {
      inherit partWidth;
      inherit (parsed) prefixLength;
      parts =
        map (
          part:
            if entry.family == "ipv4"
            then lib.toInt part
            else lib.fromHexString part
        ) (lib.splitString (
            if entry.family == "ipv4"
            then "."
            else ":"
          )
          parsed.address);
    };
    networksOverlap = left: right: let
      leftNetwork = parsedNetwork left;
      rightNetwork = parsedNetwork right;
      commonBits = lib.min leftNetwork.prefixLength rightNetwork.prefixLength;
      fullParts = builtins.div commonBits leftNetwork.partWidth;
      partialBits = commonBits - (fullParts * leftNetwork.partWidth);
      fullPartsEqual = lib.all (values: values.fst == values.snd) (
        lib.zipLists (lib.take fullParts leftNetwork.parts) (lib.take fullParts rightNetwork.parts)
      );
      partialPartsEqual =
        partialBits
        == 0
        || builtins.div
        (builtins.elemAt leftNetwork.parts fullParts)
        (pow2 (leftNetwork.partWidth - partialBits))
        == builtins.div
        (builtins.elemAt rightNetwork.parts fullParts)
        (pow2 (rightNetwork.partWidth - partialBits));
    in
      left.family == right.family && fullPartsEqual && partialPartsEqual;
    overlappingFabricPrefixes = lib.concatLists (
      lib.imap0 (
        index: left:
          map
          (right: "${left.family}:${left.name}=${left.subnet} overlaps ${right.name}=${right.subnet}")
          (lib.filter (right: networksOverlap left right) (lib.drop (index + 1) fabricPrefixEntries))
      )
      fabricPrefixEntries
    );
    invalidSourcePreservingPrefixes =
      !builtins.isAttrs sourcePreservingPrefixes
      || lib.any
      (family: !builtins.elem family addressFamilies)
      (builtins.attrNames sourcePreservingPrefixes)
      || lib.any
      (family:
        !builtins.isList sourcePreservingPrefixes.${family}
        || lib.any
        (prefix:
          !builtins.isString prefix
          || addressFamily prefix != family
          || !validSubnetForFamily family prefix)
        sourcePreservingPrefixes.${family})
      (builtins.attrNames sourcePreservingPrefixes);
    invalidRoutedFabricDefinitions =
      lib.filter
      (
        name: let
          routed = routedFabrics.${name};
          subnets =
            if builtins.isAttrs routed
            then routed.subnets or null
            else null;
          masquerade =
            if builtins.isAttrs routed
            then routed.masqueradeToUplink or {}
            else null;
        in
          !builtins.isAttrs routed
          || invalidFamilyDefinition {
            inherit masquerade subnets;
            requireSubnets = true;
          }
      )
      routedFabricNames;

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

    validForwardRule = rule: let
      sourceFamily =
        if builtins.isAttrs rule && rule ? source && builtins.isString rule.source
        then addressFamily rule.source
        else null;
      destinationFamily =
        if builtins.isAttrs rule && rule ? destination && builtins.isString rule.destination
        then addressFamily rule.destination
        else null;
    in
      builtins.isAttrs rule
      && builtins.isString (rule.from or null)
      && builtins.isString (rule.to or null)
      && builtins.elem rule.from managedFabricNames
      && builtins.elem rule.to managedFabricNames
      && (
        !(rule ? source)
        || (
          builtins.isString rule.source
          && validAddressForFamily (addressFamily rule.source) rule.source
        )
      )
      && (
        !(rule ? destination)
        || (
          builtins.isString rule.destination
          && validAddressForFamily (addressFamily rule.destination) rule.destination
        )
      )
      && compatibleFamilies sourceFamily destinationFamily
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
      ruleFamily =
        if rule ? source
        then addressFamily rule.source
        else if rule ? destination
        then addressFamily rule.destination
        else null;
      sourceMatch = lib.optionalString (rule ? source) " ${nftFamily.${ruleFamily}} saddr ${rule.source}";
      destinationMatch = lib.optionalString (rule ? destination) " ${nftFamily.${ruleFamily}} daddr ${rule.destination}";
      variants =
        lib.filter
        (variant: compatibleFamilies variant.family ruleFamily)
        (pairedSelectorVariants rule.from rule.to);
    in
      builtins.concatStringsSep "\n" (
        map
        (variant: ''
          ${variant.expression}${sourceMatch}${destinationMatch} ${protocol} dport ${renderPortSet ports} accept comment "allow ${rule.from} -> ${rule.to}"
        '')
        variants
      );

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
          lib.concatMap
          (target:
            map
            (variant: ''${variant.expression} drop comment "deny ${source} -> ${target}"'')
            (pairedSelectorVariants source target))
          deniedTargets
      )
      managedFabricNames
    );

    hostToFabricDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optionals (!(fabricPolicy source).allowFromHost) (
            map
            (variant: ''${variant.expression} ct state { new, untracked } drop comment "deny host -> ${source}"'')
            (selectorVariants "o" source)
          )
      )
      managedFabricNames
    );

    # IPv6 neighbor discovery and path-error delivery are network-layer
    # prerequisites, not application access to the host. Keep these available
    # even when a fabric otherwise restricts host traffic, just as ARP remains
    # available for IPv4 below the inet firewall layer.
    ipv6RouterInputRules = lib.optionalString (builtins.elem "ipv6" enabledFamilies) (builtins.concatStringsSep "\n" (
      map
      (iface: ''
        iifname "${iface}" meta nfproto ipv6 meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, mld-listener-report, mld-listener-done, nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert, mld2-listener-report } accept comment "allow IPv6 router control from ${iface}"
      '')
      managedPhysicalInterfaces
    ));

    ipv6RouterOutputRules = lib.optionalString (builtins.elem "ipv6" enabledFamilies) (builtins.concatStringsSep "\n" (
      map
      (iface: ''
        oifname "${iface}" meta nfproto ipv6 meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, mld-listener-query, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept comment "allow IPv6 router control to ${iface}"
      '')
      managedPhysicalInterfaces
    ));

    fabricToHostServiceRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source: let
          services = (fabricPolicy source).allowToHost.services;
          selectors = selectorVariants "i" source;
          selectorsFor = family:
            lib.filter
            (selector: compatibleFamilies selector.family family)
            selectors;
          isRouted = builtins.hasAttr source routedFabrics;
        in
          lib.optionals (!isRouted && (services.dhcpv4 or false)) (
            map
            (selector: ''${selector.expression} meta nfproto ipv4 udp sport 68 udp dport 67 accept comment "allow ${source} -> host dhcpv4"'')
            (selectorsFor "ipv4")
          )
          ++ lib.optionals (!isRouted && (services.dhcpv6 or false)) (
            map
            (selector: ''${selector.expression} meta nfproto ipv6 udp sport 546 udp dport 547 accept comment "allow ${source} -> host dhcpv6"'')
            (selectorsFor "ipv6")
          )
          ++ lib.optionals (services.dns or false) (
            lib.concatMap
            (selector: [
              ''${selector.expression} udp dport 53 accept comment "allow ${source} -> host dns udp"''
              ''${selector.expression} tcp dport 53 accept comment "allow ${source} -> host dns tcp"''
            ])
            selectors
          )
      )
      managedFabricNames
    );

    fabricToHostDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optionals (!(fabricPolicy source).allowToHost.all) (
            map
            (variant: ''${variant.expression} ct state { new, untracked } drop comment "deny ${source} -> host"'')
            (selectorVariants "i" source)
          )
      )
      managedFabricNames
    );

    fabricToUplinkDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optionals (!(fabricPolicy source).allowToUplink) (
            map
            (variant: ''${variant.expression} oifname != { ${managedFabricInterfaceSet} } drop comment "deny ${source} -> uplink"'')
            (selectorVariants "i" source)
          )
      )
      managedFabricNames
    );

    uplinkToFabricDropRules = builtins.concatStringsSep "\n" (
      lib.concatMap (
        source:
          lib.optionals (!(fabricPolicy source).allowFromUplink) (
            map
            (variant: ''iifname != { ${managedFabricInterfaceSet} } ${variant.expression} ct state { new, untracked } drop comment "deny uplink -> ${source}"'')
            (selectorVariants "o" source)
          )
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
        interfaceFabricNames
      );

    firewallInterfaces = lib.listToAttrs (
      lib.filter (entry: entry.value != {}) (
        map (
          iface: let
            sources = lib.filter (source: managedFabricInterfaces.${source} == iface) managedFabricNames;
            services = map (source: (fabricPolicy source).allowToHost.services) sources;
            udpPorts = lib.unique (
              lib.concatMap (
                service:
                  lib.optionals (service.dhcpv4 or false) [67]
                  ++ lib.optionals (service.dhcpv6 or false) [547]
                  ++ lib.optionals (service.dns or false) [53]
              )
              services
            );
            tcpPorts = lib.optional (lib.any (service: service.dns or false) services) 53;
          in {
            name = iface;
            value =
              lib.optionalAttrs (!builtins.elem iface trustedInterfaces && udpPorts != []) {
                allowedUDPPorts = udpPorts;
              }
              // lib.optionalAttrs (!builtins.elem iface trustedInterfaces && tcpPorts != []) {
                allowedTCPPorts = tcpPorts;
              };
          }
        )
        managedPhysicalInterfaces
      )
    );

    fabricMasquerade = name:
      if builtins.hasAttr name routedFabrics
      then routedFabrics.${name}.masqueradeToUplink or {}
      else interfaceFabricDefinitions.${name}.masqueradeToUplink;
    sourcePreservingPrefixesFor = family:
      lib.unique (
        (sourcePreservingPrefixes.${family} or [])
        ++ lib.concatMap
        (name:
          lib.optional
          (builtins.hasAttr family (fabricSubnets name))
          (fabricSubnets name).${family})
        managedFabricNames
      );
    perimeterNatRules =
      lib.concatMapStringsSep "\n" (
        name:
          lib.concatMapStringsSep "\n"
          (family: let
            preservedPrefixes = sourcePreservingPrefixesFor family;
          in
            lib.optionalString ((fabricMasquerade name).${family} or false) ''
              ${nftFamily.${family}} saddr ${(fabricSubnets name).${family}} ${nftFamily.${family}} daddr != ${renderAddressSet preservedPrefixes} masquerade comment "masquerade ${name} ${family} across perimeter"
            '')
          enabledFamilies
      )
      managedFabricNames;
  in {
    inherit firewallInterfaces managedFabricInterfaces managedFabricNames trustedInterfaces;
    assertions = [
      {
        assertion = !invalidEnabledFamilies;
        message = "Incus managed fabric policy enabledFamilies must be a unique non-empty subset of ipv4 and ipv6";
      }
      {
        assertion = incompleteFabricFamilies == [];
        message =
          "Every Incus managed fabric must declare a subnet for every enabled family: "
          + lib.concatStringsSep ", " incompleteFabricFamilies;
      }
      {
        assertion = duplicatePhysicalInterfaces == [];
        message =
          "Incus interface-backed fabrics must use unique physical interfaces: "
          + lib.concatStringsSep ", " duplicatePhysicalInterfaces;
      }
      {
        assertion = overlappingFabricPrefixes == [];
        message =
          "Incus managed fabric prefixes must not overlap: "
          + lib.concatStringsSep ", " overlappingFabricPrefixes;
      }
      {
        assertion = !invalidSourcePreservingPrefixes;
        message = "Incus managed fabric sourcePreservingPrefixes must contain family-keyed CIDR lists";
      }
      {
        assertion = invalidInterfaceFabricDefinitions == [];
        message =
          "Incus interface fabrics require family-keyed subnets and boolean family-keyed masqueradeToUplink values: "
          + lib.concatStringsSep ", " invalidInterfaceFabricDefinitions;
      }
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
        assertion = duplicateRoutedFabricNames == [];
        message =
          "Incus routed fabric names must not collide with interface-backed fabrics: "
          + lib.concatStringsSep ", " duplicateRoutedFabricNames;
      }
      {
        assertion = invalidRoutedFabricParents == [];
        message =
          "Incus routed fabrics must reference an interface-backed parent fabric: "
          + lib.concatStringsSep ", " invalidRoutedFabricParents;
      }
      {
        assertion = invalidRoutedFabricDefinitions == [];
        message =
          "Incus routed fabrics require family-keyed subnets and boolean family-keyed masqueradeToUplink values: "
          + lib.concatStringsSep ", " invalidRoutedFabricDefinitions;
      }
      {
        assertion = invalidForwardRules == [];
        message =
          "Incus managed fabric policy forwardRules must reference managed fabrics and include tcpPorts or udpPorts: "
          + lib.concatMapStringsSep ", " describeForwardRule invalidForwardRules;
      }
    ];
    nftablesTable =
      {
        ${tableName} = {
          family = "inet";
          content = ''
            chain input {
              type filter hook input priority -5; policy accept;

              ct state { established, related } accept
              ct state invalid drop

              ${ipv6RouterInputRules}
              ${fabricToHostServiceRules}
              ${fabricToHostDropRules}
            }

            chain output {
              type filter hook output priority -5; policy accept;

              ct state { established, related } accept
              ct state invalid drop

              ${ipv6RouterOutputRules}
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
      }
      // lib.optionalAttrs (perimeterNatRules != "") {
        "${tableName}Nat" = {
          family = "inet";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;

              ${perimeterNatRules}
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

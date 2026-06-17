{
  lib,
  pkgs ? null,
}: let
  stripNewline = value: builtins.replaceStrings ["\n"] [""] value;

  helperPackage =
    if pkgs != null
    then
      pkgs.writeShellApplication {
        name = "wg-helper";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.iproute2
          pkgs.wireguard-tools
        ];
        text = builtins.readFile ./wg-helper.sh;
      }
    else throw "wg tunnel helper package requires importing lib/services/tunnels/wg.nix with pkgs";

  mkEndpointAttrs = {
    endpoint ? null,
    persistentKeepalive ? null,
  }:
    lib.optionalAttrs (endpoint != null) {inherit endpoint;}
    // lib.optionalAttrs (persistentKeepalive != null) {inherit persistentKeepalive;};

  mkHealthExec = {
    interfaceName,
    localAddress,
    peerHost,
    peerPort,
    attempts,
    delay,
  }: "${helperPackage}/bin/wg-helper health --interface ${interfaceName} --local-address ${localAddress} --peer-host ${peerHost} --peer-port ${toString peerPort} --attempts ${toString attempts} --delay ${toString delay}";

  mkHealExec = {
    interfaceName,
    staleAfter,
    probeHost,
    probePort,
  }: "${helperPackage}/bin/wg-helper heal --interface ${interfaceName} --stale-after ${toString staleAfter} --probe-host ${probeHost} --probe-port ${toString probePort}";

  addressSet = addresses: builtins.concatStringsSep ", " addresses;
  secretNameFor = endpointName:
    if endpointName != null
    then "wg-${endpointName}-key"
    else throw "WireGuard endpoint secretName requires endpointName or explicit secretName";
  serviceNameFor = endpointName: suffix:
    if endpointName != null
    then "wg-${endpointName}-${suffix}"
    else throw "WireGuard endpoint service name requires endpointName or explicit serviceName";
  tableNameFor = endpointName:
    if endpointName != null
    then "wg_${lib.replaceStrings ["-"] ["_"] endpointName}_route"
    else throw "WireGuard routed endpoint tableName requires endpointName or explicit routedTableName";
in rec {
  inherit stripNewline helperPackage secretNameFor serviceNameFor tableNameFor;

  mkPeer = {
    allowedIPs,
    publicKey ? null,
    publicKeyFile ? null,
    endpoint ? null,
    persistentKeepalive ? null,
  }:
    {
      inherit allowedIPs;
      publicKey =
        if publicKey != null
        then publicKey
        else if publicKeyFile != null
        then stripNewline (builtins.readFile publicKeyFile)
        else throw "mkPeer requires publicKey or publicKeyFile";
    }
    // mkEndpointAttrs {
      inherit endpoint persistentKeepalive;
    };

  mkSecretBackedInterface = {
    config,
    name,
    ips,
    secretName,
    secretFile,
    secretPath ? null,
    peers,
    listenPort ? null,
    owner ? "systemd-network",
    group ? "systemd-network",
    mode ? "0400",
  }: {
    age.secrets.${secretName} =
      {
        file = secretFile;
        inherit owner group mode;
      }
      // lib.optionalAttrs (secretPath != null) {
        path = secretPath;
      };

    networking.wireguard.interfaces.${name} =
      {
        inherit ips peers;
        privateKeyFile = config.age.secrets.${secretName}.path;
      }
      // lib.optionalAttrs (listenPort != null) {
        inherit listenPort;
      };
  };

  mkEndpoint = {
    config,
    interfaceName,
    endpointName ? null,
    secretName ? secretNameFor endpointName,
    secretFile,
    secretPath ? null,
    peers,
    localAddress ? null,
    ips ? null,
    listenPort ? null,
    openListenFirewall ? false,
    allowedTCPPorts ? [],
    assertions ? [],
    owner ? "systemd-network",
    group ? "systemd-network",
    mode ? "0400",
  }: let
    resolvedIps =
      if ips != null
      then ips
      else if localAddress != null
      then ["${localAddress}/32"]
      else throw "mkEndpoint requires ips or localAddress";
  in
    assert !openListenFirewall || listenPort != null;
      lib.mkMerge [
        (mkSecretBackedInterface {
          inherit config secretName secretFile secretPath peers listenPort owner group mode;
          name = interfaceName;
          ips = resolvedIps;
        })
        (lib.mkIf openListenFirewall (mkListenFirewall {inherit listenPort;}))
        (lib.mkIf (allowedTCPPorts != []) (mkInterfaceTcpFirewall {
          inherit interfaceName allowedTCPPorts;
        }))
        (lib.mkIf (assertions != []) {inherit assertions;})
      ];

  mkListenFirewall = {listenPort}: {
    networking.firewall.allowedUDPPorts = [listenPort];
  };

  mkInterfaceTcpFirewall = {
    interfaceName,
    allowedTCPPorts,
  }: {
    networking.firewall.interfaces.${interfaceName}.allowedTCPPorts = lib.unique allowedTCPPorts;
  };

  mkPeerRoutedMasquerade = {
    tableName,
    interfaceName,
    peerAddress,
    destinationAddresses,
    enableIPv4Forwarding ? true,
  }:
    lib.mkIf (destinationAddresses != []) {
      networking = {
        firewall.extraForwardRules = ''
          iifname "${interfaceName}" ip saddr ${peerAddress} ip daddr { ${addressSet destinationAddresses} } accept
          oifname "${interfaceName}" ip daddr ${peerAddress} ct state established,related accept
        '';
        nftables.tables.${tableName} = {
          family = "ip";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              iifname "${interfaceName}" ip saddr ${peerAddress} ip daddr { ${addressSet destinationAddresses} } masquerade
            }
          '';
        };
      };

      boot.kernel.sysctl = lib.optionalAttrs enableIPv4Forwarding {
        "net.ipv4.ip_forward" = 1;
      };
    };

  mkRoutedGatewayEndpoint = {
    config,
    interfaceName,
    endpointName ? null,
    secretName ? secretNameFor endpointName,
    secretFile,
    secretPath ? null,
    peers,
    localAddress ? null,
    ips ? null,
    listenPort ? null,
    openListenFirewall ? false,
    allowedTCPPorts ? [],
    routedPeer ? {},
    routedPeerAddress ? null,
    routedDestinationAddresses ? null,
    routedTableName ? null,
    requireRoutedDestinations ? true,
    enableIPv4Forwarding ? true,
    emptyDestinationsMessage ? null,
    health ? null,
    heal ? null,
    assertions ? [],
    owner ? "systemd-network",
    group ? "systemd-network",
    mode ? "0400",
  }: let
    endpointLabel =
      if endpointName != null
      then endpointName
      else interfaceName;
    requireDestinations = routedPeer.requireDestinations or requireRoutedDestinations;
    destinationAddresses =
      routedPeer.destinationAddresses
      or (
        if routedDestinationAddresses != null
        then routedDestinationAddresses
        else throw "mkRoutedGatewayEndpoint requires routedDestinationAddresses or routedPeer.destinationAddresses"
      );
    peerAddress =
      routedPeer.address
      or (
        if routedPeerAddress != null
        then routedPeerAddress
        else throw "mkRoutedGatewayEndpoint requires routedPeerAddress or routedPeer.address"
      );
    tableName =
      routedPeer.tableName
      or (
        if routedTableName != null
        then routedTableName
        else tableNameFor endpointName
      );
    resolvedEnableIPv4Forwarding = routedPeer.enableIPv4Forwarding or enableIPv4Forwarding;
    resolvedEmptyDestinationsMessage =
      routedPeer.emptyDestinationsMessage
      or (
        if emptyDestinationsMessage != null
        then emptyDestinationsMessage
        else "WireGuard endpoint ${endpointLabel} routed destinations must not be empty."
      );
    healthDefaults = lib.optionalAttrs (endpointName != null) {
      serviceName = serviceNameFor endpointName "health";
      description = "Verify WireGuard endpoint ${endpointName}";
    };
    healDefaults = lib.optionalAttrs (endpointName != null) {
      serviceName = serviceNameFor endpointName "heal";
      timerName = serviceNameFor endpointName "heal";
      description = "Heal WireGuard endpoint ${endpointName}";
      timerDescription = "Periodically heal WireGuard endpoint ${endpointName}";
    };
  in
    lib.mkMerge (
      [
        (mkEndpoint {
          inherit
            config
            interfaceName
            secretName
            secretFile
            secretPath
            peers
            localAddress
            ips
            listenPort
            openListenFirewall
            allowedTCPPorts
            assertions
            owner
            group
            mode
            ;
        })
        (lib.mkIf requireDestinations {
          assertions = [
            {
              assertion = destinationAddresses != [];
              message = resolvedEmptyDestinationsMessage;
            }
          ];
        })
        (mkPeerRoutedMasquerade {
          inherit tableName;
          inherit interfaceName peerAddress destinationAddresses;
          enableIPv4Forwarding = resolvedEnableIPv4Forwarding;
        })
      ]
      ++ lib.optional (health != null) (mkHealthService ({
          inherit interfaceName;
          localAddress =
            if localAddress != null
            then localAddress
            else throw "mkRoutedGatewayEndpoint health requires localAddress";
        }
        // healthDefaults
        // health))
      ++ lib.optional (heal != null) (mkHealTimer ({inherit interfaceName;} // healDefaults // heal))
    );

  mkHealthService = {
    serviceName,
    interfaceName,
    localAddress,
    peerHost,
    peerPort,
    attempts ? 3,
    delay ? 2,
    description ? "Verify WireGuard tunnel route",
    after ? ["network-online.target" "systemd-networkd.service"],
    wants ? ["network-online.target"],
    wantedBy ? ["multi-user.target"],
  }: {
    systemd.services.${serviceName} = {
      inherit description after wants wantedBy;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mkHealthExec {
          inherit interfaceName localAddress peerHost peerPort attempts delay;
        };
      };
    };
  };

  mkHealTimer = {
    serviceName,
    timerName ? serviceName,
    interfaceName,
    staleAfter,
    probeHost,
    probePort,
    description ? "Heal stale WireGuard NAT mapping",
    timerDescription ? "Periodically heal stale WireGuard NAT mapping",
    after ? ["network-online.target"],
    wants ? ["network-online.target"],
    wantedBy ? ["timers.target"],
    onBootSec ? "2min",
    onUnitActiveSec ? "1min",
    randomizedDelaySec ? "10s",
  }: {
    systemd.services.${serviceName} = {
      inherit description after wants;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mkHealExec {
          inherit interfaceName staleAfter probeHost probePort;
        };
      };
    };

    systemd.timers.${timerName} = {
      description = timerDescription;
      inherit wantedBy;
      timerConfig = {
        OnBootSec = onBootSec;
        OnUnitActiveSec = onUnitActiveSec;
        RandomizedDelaySec = randomizedDelaySec;
        Unit = "${serviceName}.service";
      };
    };
  };
}

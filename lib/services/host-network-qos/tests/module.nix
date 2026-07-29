{pkgs}: let
  lib = pkgs.lib;
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    modules = [
      ../default.nix
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        networking = {
          hostName = "host-network-qos-test";
          nftables.enable = true;
          networkmanager.enable = true;
        };
        services.host-network-qos = {
          enable = true;
          interface = "eno1";
          uploadBandwidth = "900Mbit";
          downloadBandwidth = "850Mbit";
          bulkInterfaces = ["incusbr0" "tenantbr0"];
        };
      }
    ];
  };
  config = evalConfig.config;
  failedAssertions = builtins.filter (assertion: ! assertion.assertion) config.assertions;
  unit = config.systemd.services.host-network-qos;
  table = config.networking.nftables.tables.host_network_qos;
in
  assert failedAssertions == [];
  assert builtins.elem "act_ctinfo" config.boot.kernelModules;
  assert builtins.elem "ifb" config.boot.kernelModules;
  assert builtins.elem "sch_cake" config.boot.kernelModules;
  assert unit.wantedBy == ["multi-user.target"];
  assert unit.serviceConfig.Type == "oneshot";
  assert unit.serviceConfig.RemainAfterExit == true;
  assert lib.hasSuffix "host-network-qos apply" unit.serviceConfig.ExecStart;
  assert lib.hasSuffix "host-network-qos remove" unit.serviceConfig.ExecStop;
  assert unit.environment.HOST_NETWORK_QOS_IFB_INTERFACE == "ifb-eno1";
  assert unit.environment.HOST_NETWORK_QOS_UPLOAD_BANDWIDTH == "900Mbit";
  assert unit.environment.HOST_NETWORK_QOS_DOWNLOAD_BANDWIDTH == "850Mbit";
  assert table.family == "inet";
  assert lib.hasInfix ''iifname { "incusbr0", "tenantbr0" }'' table.content;
  assert lib.hasInfix "ip dscp set cs1" table.content;
  assert lib.hasInfix "ip6 dscp set cs1" table.content;
  assert lib.hasInfix "ct mark set (ct mark & 0x02ffffff) | 0x21000000" table.content;
  assert builtins.length config.networking.networkmanager.dispatcherScripts == 1;
    pkgs.runCommand "host-network-qos-module-test" {} ''
      touch "$out"
    ''

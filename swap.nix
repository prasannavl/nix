{ config, lib, pkgs, ... }:
{
  swapDevices = [
    {
      device = "/swap/swap0";
      size = 64 * 1024; # Size in MB
    }
  ];

  systemd.services =
    let
      mkSwapService = swapEntry:
        let
          swapFile = swapEntry.device;
          swapSizeMB = swapEntry.size;
          name = "ensure-swapfile-" + lib.replaceStrings ["/"] ["-"] (lib.strings.removePrefix "/" swapFile);
        in
        {
          name = name;
          value = {
            wantedBy = [ "swap.target" ];
            before = [ "swap.target" ];
            unitConfig.RequiresMountsFor = [ "/swap" ];
            serviceConfig.Type = "oneshot";
            script = ''
              if [ ! -f ${swapFile} ]; then
                echo "Creating swapfile ${swapFile} (${toString swapSizeMB}M)"
                ${pkgs.btrfs-progs}/bin/btrfs filesystem mkswapfile --size ${toString swapSizeMB}M ${swapFile}
              fi
            '';
          };
        };
    in
    lib.listToAttrs (map mkSwapService config.swapDevices);
}

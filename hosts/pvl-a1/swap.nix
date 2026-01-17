{
  config,
  lib,
  pkgs,
  ...
}: {
  swapDevices = [
    {
      device = "/swap/swap0";
      size = 64 * 1024; # Size in MB
    }
  ];

  systemd.services = let
    sanitizeUnitName = path: lib.replaceStrings ["/"] ["-"] (lib.strings.removePrefix "/" path);
    mkSwapService = swapEntry: let
      swapFile = swapEntry.device;
      swapSizeMB = swapEntry.size;
      name = "ensure-swapfile-" + sanitizeUnitName swapFile;
      swapUnit = sanitizeUnitName swapFile + ".swap";
    in {
      name = name;
      value = {
        wantedBy = [swapUnit];
        before = [swapUnit];
        after = ["swap.mount"];
        unitConfig = {
          DefaultDependencies = "no";
        };
        serviceConfig.Type = "oneshot";
        script = ''
          if [ ! -d /swap ]; then
            echo "/swap is not available, skipping swapfile creation"
            exit 0
          fi
          if [ -f ${swapFile} ]; then
            echo "${swapFile} ready"
            exit 0
          else
            echo "Creating swapfile ${swapFile} (${toString swapSizeMB}M)"
            ${pkgs.btrfs-progs}/bin/btrfs filesystem mkswapfile --size ${toString swapSizeMB}M ${swapFile}
          fi
        '';
      };
    };
  in
    lib.listToAttrs (map mkSwapService config.swapDevices);
}

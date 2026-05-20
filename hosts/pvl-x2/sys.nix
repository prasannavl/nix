# Hardware and install-storage config. The hardware module list started from
# nixos-generate-config; keep generated hardware updates narrow.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../../lib/disko
  ];

  disko.devices.disk.main = config.diskoLib.mkMain {
    diskDevice = "/dev/disk/by-id/nvme-CT4000T500SSD3_252050263EE1";
    boot = config.diskoLib.mkEfiBoot {
      size = "1G";
      partUuid = "b5d5494d-085f-4465-bb76-133d575d15f5";
    };
    root = config.diskoLib.mkLuksBtrfs {
      size = "100%";
      name = "luks-365dc847-d908-41e8-a4aa-66e187960ed6";
      luksUuid = "365dc847-d908-41e8-a4aa-66e187960ed6";
      partUuid = "ae503521-9ffb-4b30-a5ec-931a42839785";
      subvolumes = {
        "@" = {
          mountpoint = "/";
          mountOptions = ["compress=zstd"];
        };
        "@home" = {
          mountpoint = "/home";
          mountOptions = ["compress=zstd"];
        };
      };
    };
  };

  boot = {
    initrd = {
      # boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" ];
      availableKernelModules = ["nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci"];
      kernelModules = [];
    };

    kernelModules = ["kvm-amd"];
    extraModulePackages = [];
  };

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

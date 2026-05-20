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
    diskDevice = "/dev/disk/by-id/nvme-Lexar_SSD_ARES_2TB_QEC053R000846P2222";
    boot = config.diskoLib.mkEfiBoot {
      size = "1G";
      partUuid = "faa11c99-6122-468d-b86f-ef682963b4f6";
    };
    root = config.diskoLib.mkLuksBtrfs {
      size = "100%";
      name = "luks-d01c0df8-7fa4-4a15-b7d6-497a1e37f313";
      luksUuid = "d01c0df8-7fa4-4a15-b7d6-497a1e37f313";
      partUuid = "a62c98f4-056f-4747-aeb6-e006535fd919";
      subvolumes = {
        "@" = {
          mountpoint = "/";
          mountOptions = ["compress=zstd"];
        };
        "@home" = {
          mountpoint = "/home";
          mountOptions = ["compress=zstd"];
        };
        "@swap".mountpoint = "/swap";
      };
    };
  };

  boot = {
    initrd = {
      kernelModules = [];
      availableKernelModules = ["nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" "sdhci_pci"];
    };

    kernelModules = ["kvm-amd"];
    extraModulePackages = [];
  };

  swapDevices = [
    {
      device = "/swap/swap0";
      size = 64 * 1024; # Size in MB
    }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

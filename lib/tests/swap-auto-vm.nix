{pkgs}: let
  # `repairAtBoot` boots the repaired configuration directly on a disk
  # without the @swap subvolume, reproducing a boot-goal deploy onto an
  # unmigrated host. Otherwise the node boots the unrepaired configuration
  # and repairs it with a live specialisation switch.
  mkSwapNode = {
    precreateSubvolume,
    repairAtBoot,
  }: {
    lib,
    pkgs,
    ...
  }: {
    virtualisation.emptyDiskImages = [512];
    boot.initrd.availableKernelModules = ["virtio_blk"];
    systemd.services.setup-swap-test-device = {
      description = "Set up the swap test device";
      requiredBy = ["swap.mount"];
      before = ["swap.mount"];
      after = ["dev-vdb.device"];
      requires = ["dev-vdb.device"];
      path = [pkgs.btrfs-progs pkgs.util-linux];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        PrivateMounts = true;
        RuntimeDirectory = "setup-swap-test-device";
      };
      script = ''
        mount_path=/run/setup-swap-test-device

        # The reboot cycle must not re-format the persistent test disk or
        # re-create an already provisioned subvolume.
        if ! btrfs inspect-internal dump-super /dev/vdb >/dev/null 2>&1; then
          mkfs.btrfs --force /dev/vdb
        fi
        mount --types btrfs --options subvolid=5 -- /dev/vdb "$mount_path"
        ${lib.optionalString precreateSubvolume ''
          if [ ! -e "$mount_path/@swap" ]; then
            btrfs subvolume create "$mount_path/@swap"
          fi
        ''}
        umount "$mount_path"
      '';
    };
    systemd.services.prepare-btrfs-swap-subvolume-swap = lib.mkIf repairAtBoot {
      after = ["setup-swap-test-device.service"];
      requires = ["setup-swap-test-device.service"];
    };
    virtualisation.fileSystems."/swap" = {
      device = "/dev/vdb";
      fsType = "btrfs";
      options = ["subvol=@swap" "nofail" "x-systemd.device-timeout=10s"];
    };
    swapDevices = lib.mkOverride 5 [
      {
        device = "/swap/swap0";
        size = 64;
        options = ["nofail"];
      }
    ];
    imports = lib.optionals repairAtBoot [../swap-auto.nix];
    specialisation = lib.mkIf (!repairAtBoot) {
      repaired.configuration.imports = [../swap-auto.nix];
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "swap-auto";

    nodes = {
      missing = mkSwapNode {
        precreateSubvolume = false;
        repairAtBoot = false;
      };
      existing = mkSwapNode {
        precreateSubvolume = true;
        repairAtBoot = false;
      };
      coldboot = mkSwapNode {
        precreateSubvolume = false;
        repairAtBoot = true;
      };
    };

    testScript = ''
      def assert_swap_ready(machine):
          machine.wait_for_unit("swap.mount")
          machine.wait_for_unit("swap-swap0.swap")
          machine.succeed("systemctl show --property=Result --value prepare-btrfs-swap-subvolume-swap.service | grep --fixed-strings success")
          machine.succeed("btrfs subvolume show /swap")
          machine.succeed("swapon --show=NAME --noheadings | grep --fixed-strings /swap/swap0")
          machine.succeed("! systemctl --failed --no-legend | grep -E 'swap|prepare-btrfs'")
          machine.succeed("systemctl is-system-running --wait | grep --fixed-strings running")

      missing.wait_for_unit("multi-user.target")
      missing.succeed("systemctl is-failed swap.mount")
      missing.succeed("/run/current-system/specialisation/repaired/bin/switch-to-configuration test")
      assert_swap_ready(missing)

      missing.succeed("systemctl stop swap-swap0.swap swap.mount")
      missing.succeed("systemctl start swap-swap0.swap")
      missing.wait_for_unit("swap-swap0.swap")

      # Boot-goal migration: the repaired configuration provisions @swap on
      # the first boot of an unmigrated disk, without a live switch.
      coldboot.wait_for_unit("multi-user.target")
      assert_swap_ready(coldboot)

      # The same repaired configuration must converge identically on a full
      # power cycle: the provisioned subvolume and swapfile persist with an
      # unchanged identity and no unit enters a failed state. The device
      # number is deliberately excluded because it is not stable across
      # reboots.
      swap_identity = coldboot.succeed("stat --format=%i:%s /swap/swap0").strip()
      coldboot.shutdown()
      coldboot.start()
      coldboot.wait_for_unit("multi-user.target")
      assert_swap_ready(coldboot)
      assert coldboot.succeed("stat --format=%i:%s /swap/swap0").strip() == swap_identity

      existing.wait_for_unit("multi-user.target")
      existing.wait_for_unit("swap.mount")
      existing.wait_for_unit("swap-swap0.swap")
      swap_identity = existing.succeed("stat --format=%i:%s /swap/swap0").strip()
      existing.succeed("/run/current-system/specialisation/repaired/bin/switch-to-configuration test")
      assert_swap_ready(existing)
      assert existing.succeed("stat --format=%i:%s /swap/swap0").strip() == swap_identity
    '';
  }

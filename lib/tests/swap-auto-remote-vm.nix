{pkgs}: let
  inherit
    (import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs)
    snakeOilPrivateKey
    snakeOilPublicKey
    ;
  tlsCertificate = pkgs.runCommand "swap-auto-headscale-certificate" {nativeBuildInputs = [pkgs.openssl];} ''
    mkdir "$out"
    openssl req \
      -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
      -out "$out/cert.pem" -keyout "$out/key.pem" \
      -subj /CN=headscale -addext subjectAltName=DNS:headscale
  '';
  remoteAccess = {
    services.tailscale.enable = true;
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };
    security.pki.certificateFiles = ["${tlsCertificate}/cert.pem"];
    users.users.root.openssh.authorizedKeys.keys = [snakeOilPublicKey];
    networking.firewall.trustedInterfaces = ["tailscale0"];
  };

  mkFailureNode = {
    bootFailure ? false,
    failure,
  }: {
    lib,
    pkgs,
    ...
  }: let
    swapConfiguration = {
      imports = [../swap-auto.nix];
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
      systemd.services =
        {
          prepare-btrfs-swap-subvolume-swap = {
            after = ["setup-swap-test-device.service"];
            requires = ["setup-swap-test-device.service"];
          };
        }
        // lib.optionalAttrs (failure == "creation") {
          "mkswap-swap-swap0".script = lib.mkForce ''
            exit 1
          '';
        }
        // lib.optionalAttrs (failure == "activation") {
          "mkswap-swap-swap0".script = lib.mkForce ''
            ${pkgs.coreutils}/bin/truncate --size 64M /swap/swap0
          '';
        };
    };
  in {
    imports =
      [remoteAccess]
      ++ lib.optional bootFailure swapConfiguration;
    virtualisation.emptyDiskImages = [512];
    boot.initrd.availableKernelModules = ["virtio_blk"];
    systemd.services.setup-swap-test-device = {
      description = "Set up the failing swap test device";
      wantedBy = ["multi-user.target"];
      before = ["multi-user.target"];
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

        mkfs.btrfs --force /dev/vdb
        mount --types btrfs --options subvolid=5 -- /dev/vdb "$mount_path"
        ${lib.optionalString (failure == "preparation") ''
          mkdir "$mount_path/@swap"
        ''}
        umount "$mount_path"
      '';
    };
    specialisation = lib.mkIf (!bootFailure) {
      failing.configuration = swapConfiguration;
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "swap-auto-remote-recovery";

    nodes = {
      headscale = {
        services.headscale = {
          enable = true;
          port = 8080;
          settings = {
            server_url = "https://headscale";
            ip_prefixes = ["100.64.0.0/10"];
            derp = {
              server = {
                enabled = true;
                region_id = 999;
                stun_listen_addr = "0.0.0.0:3478";
              };
              urls = [];
            };
            dns = {
              base_domain = "tailnet";
              override_local_dns = false;
            };
          };
        };
        services.nginx = {
          enable = true;
          virtualHosts.headscale = {
            addSSL = true;
            sslCertificate = "${tlsCertificate}/cert.pem";
            sslCertificateKey = "${tlsCertificate}/key.pem";
            locations."/" = {
              proxyPass = "http://127.0.0.1:8080";
              proxyWebsockets = true;
            };
          };
        };
        networking.firewall = {
          allowedTCPPorts = [443];
          allowedUDPPorts = [3478];
        };
        environment.systemPackages = [pkgs.headscale];
      };

      peer = {
        imports = [remoteAccess];
      };

      prepare_failure = mkFailureNode {failure = "preparation";};
      create_failure = mkFailureNode {failure = "creation";};
      activate_failure = mkFailureNode {failure = "activation";};
      prepare_boot_failure = mkFailureNode {
        bootFailure = true;
        failure = "preparation";
      };
      create_boot_failure = mkFailureNode {
        bootFailure = true;
        failure = "creation";
      };
      activate_boot_failure = mkFailureNode {
        bootFailure = true;
        failure = "activation";
      };
    };

    testScript = ''
      import shlex

      start_all()
      headscale.wait_for_unit("headscale.service")
      headscale.wait_for_open_port(443)
      headscale.succeed("headscale users create test")
      auth_key = headscale.succeed("headscale preauthkeys -u 1 create --reusable").strip()
      up_command = f"tailscale up --login-server https://headscale --auth-key {shlex.quote(auth_key)}"

      live_failure_machines = [prepare_failure, create_failure, activate_failure]
      boot_failure_machines = [prepare_boot_failure, create_boot_failure, activate_boot_failure]
      failure_machines = live_failure_machines + boot_failure_machines

      for machine in failure_machines:
          machine.wait_for_unit("multi-user.target")
          machine.succeed("systemctl start setup-swap-test-device.service")
          machine.succeed("systemctl is-active setup-swap-test-device.service")

      for machine in [peer] + failure_machines:
          machine.wait_for_unit("tailscaled.service")
          machine.succeed(up_command)
          machine.wait_until_succeeds("test -n \"$(tailscale ip -4)\"")

      peer.succeed("install --directory --mode 0700 /root/.ssh")
      peer.succeed("install --mode 0600 ${snakeOilPrivateKey} /root/.ssh/swap-auto-test")

      def assert_remote_access(machine):
          tailnet_ip = machine.succeed("tailscale ip -4").strip()
          peer.wait_until_succeeds(f"tailscale ping {shlex.quote(tailnet_ip)}")
          peer.succeed(
              "ssh -i /root/.ssh/swap-auto-test -o ConnectTimeout=2 "
              "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
              f"root@{shlex.quote(tailnet_ip)} true"
          )

      def assert_failure_survival(machine):
          machine.succeed("systemctl is-active multi-user.target sshd.service tailscaled.service")
          machine.succeed("test -z \"$(swapon --show=NAME --noheadings)\"")
          assert_remote_access(machine)

      for machine in live_failure_machines:
          assert_remote_access(machine)
          machine.fail("/run/current-system/specialisation/failing/bin/switch-to-configuration test")
          assert_failure_survival(machine)

      for machine in boot_failure_machines:
          assert_failure_survival(machine)

      for machine in [prepare_failure, prepare_boot_failure]:
          machine.succeed("systemctl is-failed prepare-btrfs-swap-subvolume-swap.service")
          machine.succeed("systemctl show --property=ActiveState --value swap.mount | grep --fixed-strings --line-regexp inactive")
          machine.succeed("! mountpoint --quiet /swap")

      for machine in [create_failure, create_boot_failure]:
          machine.succeed("systemctl show --property=Result --value prepare-btrfs-swap-subvolume-swap.service | grep --fixed-strings success")
          machine.succeed("systemctl is-active swap.mount")
          machine.succeed("systemctl is-failed mkswap-swap-swap0.service")
          machine.succeed("! systemctl is-active swap-swap0.swap")

      for machine in [activate_failure, activate_boot_failure]:
          machine.succeed("systemctl show --property=Result --value prepare-btrfs-swap-subvolume-swap.service | grep --fixed-strings success")
          machine.succeed("systemctl is-active swap.mount")
          machine.succeed("systemctl show --property=Result --value mkswap-swap-swap0.service | grep --fixed-strings success")
          machine.succeed("systemctl is-failed swap-swap0.swap")
    '';
  }

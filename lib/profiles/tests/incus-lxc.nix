{pkgs}: let
  lib = pkgs.lib;
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    specialArgs = {
      hostName = "incus-lxc-profile-test";
      stack.nixosConfig = {...}: {
        disabledActivationScripts = {};
        disabledGroups = {};
        disabledUsers = {};
      };
    };
    modules = [
      ../incus-lxc.nix
      {
        options.age.secrets = lib.mkOption {
          type = lib.types.attrs;
          default = {};
        };
        options.home-manager = lib.mkOption {
          type = lib.types.attrs;
          default = {};
        };
        config = {
          networking.hostName = "incus-lxc-profile-test";
          users.allowNoPasswordLogin = true;
        };
      }
    ];
  };

  config = evalConfig.config;
  linksUnit = config.systemd.services.nixos-lxc-boot-system-links;
  activationUnit = config.systemd.services.nixos-lxc-boot-activation;
in
  assert linksUnit.wantedBy == ["sysinit.target"];
  assert linksUnit.restartIfChanged == false;
  assert linksUnit.stopIfChanged == false;
  assert builtins.elem "register-nix-paths.service" linksUnit.before;
  assert activationUnit.wantedBy == ["sysinit.target"];
  assert activationUnit.restartIfChanged == false;
  assert activationUnit.stopIfChanged == false;
  assert builtins.elem "register-nix-paths.service" activationUnit.after;
  assert ! builtins.elem "register-nix-paths.service" activationUnit.before;
  assert lib.hasInfix "nix-env -p /nix/var/nix/profiles/system --set \"$system_config\"" activationUnit.script;
  assert lib.hasInfix "ln -sfn \"$system_config\" /run/current-system" activationUnit.script;
  assert lib.hasInfix "ln -sfn \"$system_config\" /run/booted-system" activationUnit.script;
    pkgs.runCommand "incus-lxc-profile-test" {} ''
      touch "$out"
    ''

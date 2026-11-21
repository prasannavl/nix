{pkgs}: let
  lib = pkgs.lib;
  isolate = name:
    builtins.path {
      path = ../. + "/${name}";
      name = "ab-${name}-optional-features-test";
    };
  core = import (isolate "core");
  system = import (isolate "system") {inherit core;};
  services = (import (isolate "services") {inherit core;}).mk {inherit pkgs;};
  evaluate = modules:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      inherit pkgs;
      modules = [{system.stateVersion = "25.11";}] ++ modules;
    }).config;
  cache =
    (system.nix.module {
      cachePolicy = {
        substituters = ["https://repository.test" "https://first.test" "https://repository.test" "https://last.test"];
        trustedPublicKeys = ["repository-key" "first-key" "repository-key" "last-key"];
      };
    }) {
      inherit lib pkgs;
      config.system.nixos.release = "26.05";
    };
  unconfiguredNix = (system.nix.module {}) {lib = lib;};
  base = evaluate [];
  desktopWm = evaluate [system.modules.desktop.wm];
  customWm = evaluate [(system.profiles.mkWmModule {renderDevice = "/dev/dri/test-render";})];
  gpuPackage = pkgs.runCommand "nvidia-policy-probe" {version = "999.0";} "touch $out";
  gpu = profile:
    evaluate [
      system.modules.options
      profile
      {hardware.nvidia.package = gpuPackage;}
    ];
  laptop = gpu system.hardware.devices.lenovoLegion5;
  asus = gpu system.hardware.devices.asusFa401wv;
  cachePackage = pkgs.writeShellScriptBin "kache" "exit 0";
  enabled = evaluate [
    system.modules.desktop.audio
    system.modules.desktop.base
    system.modules.desktop.flatpak
    system.modules.desktop.gdm
    system.modules.desktop.gnome
    system.modules.desktop.keyd
    system.modules.desktop.printing
    system.modules.desktop.power
    system.modules.gpg
    system.modules.mdns
    system.modules.networkWifi
    system.hardware.tpm
    services.kache.module
    {
      services.keyd.enable = true;
      services.kache = {
        enable = true;
        package = cachePackage;
        daemon.enable = true;
      };
    }
  ];
in
  assert cache.nix.settings.extra-substituters == ["https://repository.test" "https://first.test" "https://last.test"];
  assert cache.nix.settings.extra-trusted-public-keys == ["repository-key" "first-key" "last-key"];
  assert !base.services.flatpak.enable;
  assert !base.services.desktopManager.gnome.enable;
  assert unconfiguredNix.nix.settings.extra-substituters == [];
  assert unconfiguredNix.nix.settings.extra-trusted-public-keys == [];
  assert !(unconfiguredNix ? system) && !(unconfiguredNix ? nixpkgs);
  assert !(unconfiguredNix.nix ? gc) && !(unconfiguredNix.nix ? package);
  assert desktopWm.programs.sway.enable && desktopWm.programs.niri.enable;
  assert lib.hasInfix "/dev/dri/test-render" customWm.programs.sway.extraSessionCommands;
  assert laptop.hardware.nvidia.prime.nvidiaBusId == "PCI:1:0:0";
  assert asus.hardware.nvidia.prime.nvidiaBusId == "PCI:100:0:0";
  assert laptop.hardware.nvidia.package.drvPath == gpuPackage.drvPath;
  assert asus.hardware.nvidia.package.drvPath == gpuPackage.drvPath;
  assert enabled.services.pipewire.enable;
  assert !enabled.services.pulseaudio.enable;
  assert enabled.services.displayManager.gdm.enable;
  assert enabled.services.desktopManager.gnome.enable;
  assert enabled.services.flatpak.enable;
  assert enabled.services.printing.enable;
  assert enabled.services.avahi.enable;
  assert enabled.networking.networkmanager.wifi.backend == "iwd";
  assert enabled.networking.wireless.iwd.settings.DriverQuirks.PowerSaveDisable == "mt7921e";
  assert builtins.elem "CAP_SETGID" enabled.systemd.services.keyd.serviceConfig.AmbientCapabilities;
  assert enabled.systemd.services.systemd-suspend.unitConfig.StartLimitBurst == 3;
  assert enabled.environment.variables.RUSTC_WRAPPER == lib.getExe cachePackage;
  assert enabled.systemd.user.services.kache.serviceConfig.ExecStart == "${lib.getExe cachePackage} daemon run";
    pkgs.runCommand "ab-system-optional-features-test" {} ''
      touch "$out"
    ''

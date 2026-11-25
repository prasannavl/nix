{pkgs}: let
  ab = (import ../../../../ab/core).mk {pkgs = pkgs;};
  hello = pkgs.example-hello-rust;
  # Child parity checks the export exists. Consume it as a NixOS module,
  # without realising hello-rust or a system closure.
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    modules = [
      (ab.flake.modules {build = hello;}).default
      {
        system.stateVersion = "26.05";
        services.hello-rust.enable = true;
      }
    ];
  };
  config = evaluated.config;
in
  assert config.services.hello-rust.package.drvPath == hello.drvPath;
  assert config.systemd.services.hello-rust.serviceConfig.ExecStart == pkgs.lib.getExe hello;
  assert config._ab.nixos.registeredUnits
  == [
    {
      name = "hello-rust";
      scope = "system";
      unit = "hello-rust.service";
      user = null;
    }
  ];
    pkgs.runCommand "pvl-nixos-core-test" {} ''touch "$out"''

{pkgs}: let
  lib = pkgs.lib;
  package = pkgs.callPackage ../../../../lib/ext/pi/pi-web {};
  evaluate = host: settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      pkgs = pkgs;
      specialArgs.ab = (import ../../../../ab).forPkgs {pkgs = pkgs;};
      modules = [
        (../../../../hosts + "/${host}/services/pi-web.nix")
        {
          system.stateVersion = "25.11";
          networking.hostName = host;
          services.tailscale.enable = true;
          users.users = {
            pvl = {
              isNormalUser = true;
              home = "/home/pvl";
              packages = [pkgs.hello];
            };
            tester = {
              isNormalUser = true;
              home = "/home/tester";
            };
          };
        }
        settings
      ];
    }).config;
  verify = host: let
    config = evaluate host {};
    service = config.services.pi-web;
    unit = config.systemd.services.pi-web;
    override = evaluate host {
      services.pi-web = {
        package = pkgs.hello;
        user = "tester";
      };
    };
  in
    assert service.enable && service.tailnetAccess && !service.mcp.enable;
    assert service.package.drvPath == package.drvPath;
    assert service.user == "pvl";
    assert service.allowedHosts == [host "${host}.tailcaaad.ts.net"];
    assert unit.serviceConfig.User == "pvl";
    assert unit.serviceConfig.WorkingDirectory == "/home/pvl";
    assert unit.serviceConfig.ExecStart == "${lib.getExe package} --no-open --hostname 0.0.0.0 --port 30141";
    assert builtins.elem "PI_WEB_DISABLE_MCP=1" unit.serviceConfig.Environment;
    assert builtins.elem "PI_WEB_ALLOWED_HOSTS=${host},${host}.tailcaaad.ts.net" unit.serviceConfig.Environment;
    assert unit.path == config.users.users.pvl.packages ++ [config.system.path];
    assert !unit.enableDefaultPath;
    assert lib.hasInfix ''iifname "tailscale0" tcp dport 30141 accept'' config.networking.firewall.extraInputRules;
    assert override.services.pi-web.package.drvPath == pkgs.hello.drvPath;
    assert override.systemd.services.pi-web.serviceConfig.User == "tester";
    assert override.systemd.services.pi-web.serviceConfig.WorkingDirectory == "/home/tester"; true;
in {
  pvl-pi-web = assert builtins.all verify ["pvl-a1" "pvl-l5"];
    pkgs.runCommand "pvl-pi-web-test" {} ''
      touch "$out"
    '';
}

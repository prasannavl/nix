{
  pkgs,
  ab,
  buildController ? ../abird-host-manager,
}:
ab.package.withDeps {
  inherit buildController;
} ({buildController}: let
  app = pkgs.writeShellApplication {
    name = "nixbot";
    meta = {
      description = "NixOS management bot";
      platforms = pkgs.lib.platforms.linux;
      mainProgram = "nixbot";
    };
    runtimeInputs = with pkgs; [
      buildController
      age
      cloudflared
      coreutils
      findutils
      gawk
      git
      jq
      getent
      gnugrep
      gnused
      inetutils
      iproute2
      nix
      openssh
      opentofu
      procps
      util-linux
    ];
    text = ''
      export NIXBOT_IN_NIX_SHELL=1
      exec ${pkgs.bash}/bin/bash ${./nixbot.sh} "$@"
    '';
  };
  tests = import ./tests {
    inherit pkgs app;
  };
  drv = ab.build.shell {
    inherit pkgs;
    src = ./.;
    build = pkgs.symlinkJoin {
      pname = "nixbot";
      name = "nixbot";
      paths = [app];
      postBuild = ''
        install -Dm0644 ${./nixbot.bash} \
          $out/share/bash-completion/completions/nixbot
      '';
      meta = app.meta;
    };
    extraPassthru = {
      tests = tests;
      flakeExtraNixosModules.nixbot = import ./nixos-module.nix;
    };
  };
in
  drv)

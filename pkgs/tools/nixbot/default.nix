{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  app = pkgs.writeShellApplication {
    name = "nixbot";
    meta = {
      description = "NixOS management bot";
      platforms = pkgs.lib.platforms.linux;
      mainProgram = "nixbot";
    };
    runtimeInputs = with pkgs; [
      age
      coreutils
      findutils
      git
      jq
      nix
      nixos-rebuild-ng
      openssh
      opentofu
      procps
      cloudflared
    ];
    text = ''
      export NIXBOT_IN_NIX_SHELL=1
      exec ${pkgs.bash}/bin/bash ${./nixbot.sh} "$@"
    '';
  };
  drv = pkgHelper.mkShellScriptDerivation {
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
      flakeExtraNixosModules.nixbot = import ./nixos-module.nix;
    };
  };
in
  drv

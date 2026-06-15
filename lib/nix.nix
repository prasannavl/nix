{
  config,
  lib,
  pkgs,
  ...
}: let
  nixosLessThan2605 = version: lib.versionOlder version "26.05";
  pvlBuilderCacheUrl = "http://pvl-x2:5000";
  pvlBuilderPublicKey = "pvl-1:gW+9RR4ONrwIBL1mpEwORnHdqdcixPnkm6xHYLiu4o4=";
  abirdBuilderPublicKey = "abird-1:DYGYgDPKODWjpQMohvZsfMRAiLn5XCc6efYhVprzL50=";
in {
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = [
        "https://cache.nixos.org"
      ];
      extra-substituters = [
        pvlBuilderCacheUrl
        # Another geo-cache for nixos.org, no key needed, as it's the same
        # "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
        "https://nix-community.cachix.org"
        "https://numtide.cachix.org"
      ];
      extra-trusted-public-keys = [
        pvlBuilderPublicKey
        abirdBuilderPublicKey
        # "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
      ];
    };
    package = let
      nixPackage =
        if nixosLessThan2605 config.system.nixos.release
        then pkgs.nixVersions.nix_2_33
        else pkgs.nixVersions.nix_2_34;
    in
      nixPackage;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  # Handy to have this linked for debugging
  environment.pathsToLink = ["/libexec"];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11";
}

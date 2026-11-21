{
  ab,
  config,
  lib,
  pkgs,
  repository,
  ...
}: let
  cachePolicy =
    repository.nix
    // {
      substituters =
        (repository.nix.substituters or [])
        ++ [
          "https://nix-community.cachix.org"
          "https://numtide.cachix.org"
          "https://cache.numtide.com"
          "https://go-overlay.cachix.org"
          "https://fenix.cachix.org"
        ];
      trustedPublicKeys =
        (repository.nix.trustedPublicKeys or [])
        ++ [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
          "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
          "go-overlay.cachix.org-1:rJ155O3K6WUyUcoKE4MqcC6JcLlK2vPXnP5/76BxWD8="
          "fenix.cachix.org-1:ecJhr+RdYEdcVgUkjruiYhjbBloIEGov7bos90cZi0Q="
        ];
    };
in {
  imports = [
    ./nix-builder.nix
    (ab.system.nix.module {cachePolicy = cachePolicy;})
  ];

  nix = {
    package =
      if lib.versionOlder config.system.nixos.release "26.05"
      then pkgs.nixVersions.nix_2_33
      else pkgs.nixVersions.nix_2_34;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
  nixpkgs.config.allowUnfree = true;
  environment.pathsToLink = ["/libexec"];
  # Installation baseline; never derive this from the running NixOS release.
  system.stateVersion = "25.11";
}

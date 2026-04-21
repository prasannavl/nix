{inputs}: final: prev: let
  inherit (final.stdenv.hostPlatform) system;
  inherit (inputs.p7-borders.packages.${system}) p7-borders;
  inherit (inputs.p7-cmds.packages.${system}) p7-cmds;
  # p7-borders = final.callPackage ../pkgs/ext/p7-borders.nix {};
  # p7-cmds = final.callPackage ../pkgs/ext/p7-cmds.nix {};
in rec {
  pvl.gnomeExtensions = {
    inherit p7-borders p7-cmds;
  };

  gdm = prev.gdm.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ./patches/gdm-register-session-delay-3s.patch
      ];
  });

  gnomeExtensions =
    prev.gnomeExtensions
    // pvl.gnomeExtensions;
}

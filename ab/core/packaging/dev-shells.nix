{lib}: rec {
  mkDefault = {
    pkgs,
    rootPackages ? [],
    shellHook ? "",
  }:
    pkgs.mkShell {
      name = "nix-repo";
      packages = rootPackages;
      inherit shellHook;
    };

  mkFull = {
    pkgs,
    rootPackages ? [],
    childPackages ? {},
    shellHook ? "",
  }: let
    childShells = lib.pipe childPackages [
      builtins.attrValues
      (builtins.filter (p: (p.passthru or {}) ? devShell))
      (map (p: p.passthru.devShell))
    ];
  in
    pkgs.mkShell {
      name = "nix-repo-full";
      packages = rootPackages;
      inputsFrom = childShells;
      inherit shellHook;
    };

  mkDevShells = args: {
    default = mkDefault (builtins.removeAttrs args ["childPackages"]);
    full = mkFull args;
  };
}

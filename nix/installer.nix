{
  repoRoot ? ../.,
  userData ? import ../users/userdata.nix,
  userProfilesRoot ? ../users,
}: let
  ab = import ../ab;
  systemComponent = ab.system;

  moduleFor = installerArgs @ {installerUsers ? {}, ...}: moduleArgs @ {
    inputs,
    lib,
    modulesPath,
    pkgs,
    ...
  }: let
    repoSource = lib.cleanSourceWith {
      src = repoRoot;
      filter = path: _type: let
        root = toString repoRoot;
        rel = lib.removePrefix "${root}/" (toString path);
        base = baseNameOf path;
        isSecretKey =
          lib.hasPrefix "data/secrets/" rel
          && lib.hasSuffix ".key" rel;
      in
        !(
          base
          == ".git"
          || base == ".direnv"
          || base == "result"
          || lib.hasPrefix "result-" base
          || rel == "tmp"
          || lib.hasPrefix "tmp/" rel
          || isSecretKey
        );
    };
    userProfiles = lib.filterAttrs (_: profile: profile != null) (builtins.listToAttrs (
      map
      (userName: let
        profilePath = userProfilesRoot + "/${userName}/default.nix";
      in {
        name = userName;
        value =
          if builtins.pathExists profilePath
          then import profilePath
          else null;
      })
      (builtins.attrNames installerUsers)
    ));
    module = systemComponent.installer.module (
      installerArgs
      // {
        inherit repoSource userData userProfiles;
        storageOverrideRepoPath = "ab/system/installer/storage-override.nix";
      }
    );
  in
    module (
      moduleArgs
      // {
        inherit inputs modulesPath pkgs;
      }
    );
in {
  inherit moduleFor;
}

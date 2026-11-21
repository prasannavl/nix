{
  abCoreSource,
  abRepoSource,
  nixpkgsPath,
  system,
}: let
  pkgs = import nixpkgsPath {inherit system;};
  core = import abCoreSource;
  repository = import ./repository.nix;
  repoComponent = import abRepoSource {
    inherit core repository;
  };
  ab = core.mk {
    inherit pkgs;
    extensions = [repoComponent.extension];
  };
in {
  inherit ab core pkgs repoComponent repository;
  inherit (ab.repo) checks packages tasks;
}

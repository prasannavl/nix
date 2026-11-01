{
  fetchFromGitHub,
  git,
  lib,
  rustPlatform,
}: let
  source = (import ./sources.nix).tuicr;
in
  rustPlatform.buildRustPackage {
    pname = "tuicr";
    version = source.version;

    src = fetchFromGitHub {
      owner = source.owner;
      repo = source.repo;
      rev = source.rev;
      hash = source.hash;
    };

    cargoHash = source.cargoHash;

    # The test suite shells out to git to build throwaway repositories.
    nativeBuildInputs = [git];

    meta = {
      description = "A code review TUI with vim keybindings";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "tuicr";
      platforms = lib.platforms.all;
    };
  }

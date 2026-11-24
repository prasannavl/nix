{
  fetchFromGitHub,
  git,
  lib,
  rustPlatform,
  unixtools,
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

    # Tests create Git repositories and check timed-out child processes with ps.
    nativeCheckInputs = [git unixtools.ps];

    meta = {
      description = "A code review TUI with vim keybindings";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "tuicr";
      platforms = lib.platforms.all;
    };
  }

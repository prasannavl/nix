{
  pkgs,
  lib,
  release ? "kanidm-server",
}: let
  source = (import ./sources.nix).${release};
  buildPkgs =
    if source.cli.unstable
    then pkgs.unstable
    else pkgs;
  package = buildPkgs.${source.cli.package};
in
  assert lib.assertMsg
  (lib.versionAtLeast buildPkgs.rustc.version source.cli.rustVersion)
  "Kanidm ${source.version} requires Rust ${source.cli.rustVersion} or newer";
    package.overrideAttrs (old: rec {
      version = source.version;
      src = buildPkgs.fetchFromGitHub {
        owner = "kanidm";
        repo = "kanidm";
        tag = "v${version}";
        hash = source.cli.sourceHash;
      };
      cargoDeps = buildPkgs.rustPlatform.fetchCargoVendor {
        src = src;
        name = source.cli.vendorName;
        hash = source.cli.cargoHash;
      };
      # This repository pins each CLI and server image together as one reviewed
      # compatibility unit (see sources.nix). nixpkgs marks the whole 1.10 series
      # end-of-life, which would otherwise block evaluating the repo's own pin.
      # Drop only that EOL notice; any other known vulnerability still blocks.
      meta =
        (old.meta or {})
        // {
          knownVulnerabilities =
            builtins.filter (entry: !(lib.hasInfix "has reached end-of-life" entry))
            (old.meta.knownVulnerabilities or []);
        };
      passthru = old.passthru // {release = source;};
    })

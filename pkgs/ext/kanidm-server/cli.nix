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
      passthru = old.passthru // {release = source;};
    })

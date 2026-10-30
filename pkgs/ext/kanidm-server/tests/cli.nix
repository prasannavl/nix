{pkgs}: let
  lib = pkgs.lib;
  sources = import ../sources.nix;
  mkCli = release: old: let
    buildPkgs = {
      rustc.version = "1000";
      fetchFromGitHub = args: args;
      rustPlatform.fetchCargoVendor = args: args;
      ${sources.${release}.cli.package}.overrideAttrs = override: override old;
    };
  in
    import ../cli.nix {
      inherit lib release;
      pkgs = buildPkgs // {unstable = buildPkgs;};
    };
  old = {
    passthru.retained = true;
    meta = {
      description = "retained metadata";
      knownVulnerabilities = [
        "Kanidm 1.10 has reached end-of-life and is unsupported"
        "CVE-2099-1234"
        "Another security advisory"
      ];
    };
  };
  remaining = ["CVE-2099-1234" "Another security advisory"];
  validRelease = release: let
    package = mkCli release old;
    source = sources.${release};
  in
    package.meta.knownVulnerabilities
    == remaining
    && package.meta.description == old.meta.description
    && package.passthru.retained
    && package.passthru.release == source
    && package.version == source.version
    && package.src.tag == "v${source.version}"
    && package.src.hash == source.cli.sourceHash
    && package.cargoDeps.hash == source.cli.cargoHash;
  noMeta = mkCli "kanidm-server" {passthru = {};};
  noAdvisories = mkCli "kanidm-server" {
    passthru = {};
    meta.description = "no advisories";
  };
in
  assert builtins.all validRelease (builtins.attrNames sources);
  assert noMeta.meta.knownVulnerabilities == [];
  assert noAdvisories.meta.knownVulnerabilities == [];
  assert noAdvisories.meta.description == "no advisories";
    pkgs.runCommand "kanidm-cli-metadata-test" {} ''
      touch "$out"
    ''

{
  pkgs ? null,
  inputs ? {},
}: let
  contract = import ../toolchain-contract.nix;

  resolverFor = packageSet: let
    inherit (packageSet) lib;
    platformId = platform: platform.config or platform.system;
    native =
      platformId packageSet.stdenv.buildPlatform
      == platformId packageSet.stdenv.hostPlatform;
    exactVersion = version: version != lib.versions.majorMinor version;
    nixpkgsGo = version:
      if version == null
      then packageSet.go
      else let
        attr = "go_${lib.replaceStrings ["."] ["_"] (lib.versions.majorMinor version)}";
        candidate = contract.attrOrNull packageSet attr;
      in
        if candidate == null
        then null
        else if !exactVersion version || candidate.version == version
        then candidate
        else null;
    overlayGo = version: let
      source =
        if !native
        then throw "go-toolchain: go-overlay is unsupported for cross package sets; use nixpkgs or a resolved spliced compiler"
        else inputs.go-overlay
          or (throw "go-toolchain: provider `go-overlay` requires pinned input `go-overlay`");
      providerPkgs = packageSet.extend (import source);
    in
      providerPkgs.go-bin.versions.${version}
      or (throw "go-toolchain: go-overlay does not provide Go ${version}");
    resolve = parsed: let
      version = contract.optionalString parsed.fail "version" (parsed.spec.version or null);
    in
      if parsed.provider == "resolved"
      then {
        derivation = parsed.spec.pkg;
        provider = "resolved";
      }
      else if parsed.provider == "nixpkgs"
      then let
        selected = nixpkgsGo version;
      in
        if selected != null
        then {
          derivation = selected;
          provider = "nixpkgs";
        }
        else parsed.fail "nixpkgs does not provide requested Go ${version}"
      else if parsed.provider == "go-overlay"
      then
        if !exactVersion version
        then parsed.fail "go-overlay requires an exact version"
        else {
          derivation = overlayGo version;
          provider = "go-overlay";
        }
      else let
        selected = nixpkgsGo version;
      in
        if selected != null
        then {
          derivation = selected;
          provider = "nixpkgs";
        }
        else if version != null && exactVersion version
        then {
          derivation = overlayGo version;
          provider = "go-overlay";
        }
        else parsed.fail "nixpkgs has no Go ${version} line";
    toolchainFor = requested: let
      parsed = contract.parse {
        language = "go";
        contract = requested;
        defaultProvider = "auto";
        allowedFields = {
          auto = ["provider" "version"];
          nixpkgs = ["provider" "version"];
          go-overlay = ["provider" "version"];
          resolved = ["provider" "pkg"];
        };
        requiredFields = {
          go-overlay = ["version"];
          resolved = ["pkg"];
        };
      };
      selected = resolve parsed;
    in
      contract.result {
        language = "go";
        default = packageSet.go;
        pkg = selected.derivation;
        inherit (selected) provider;
        fail = parsed.fail;
        tools.go = selected.derivation;
        build = {
          mod = packageSet.buildGoModule.override {go = selected.derivation;};
        };
      };
  in {
    inherit toolchainFor;
  };
in {
  toolchainFor =
    if pkgs == null
    then _: throw "go-toolchain: toolchainFor requires a package set"
    else (resolverFor pkgs).toolchainFor;

  overlay = final: prev: {
    toolchains =
      (prev.toolchains or {})
      // {
        go = (resolverFor final).toolchainFor;
      };
  };
}

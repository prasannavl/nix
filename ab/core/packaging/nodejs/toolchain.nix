{pkgs ? null}: let
  contract = import ../toolchain-contract.nix;

  resolverFor = packageSet: let
    select = version:
      if version == null
      then packageSet.nodejs
      else let
        parts = builtins.splitVersion version;
        major = builtins.head parts;
        attr = "nodejs_${major}";
        candidate = contract.attrOrNull packageSet attr;
        full = builtins.length parts == 3;
      in
        if candidate == null
        then null
        else if builtins.length parts == 1 || (full && candidate.version == version)
        then candidate
        else null;
    toolchainFor = requested: let
      parsed = contract.parse {
        language = "node";
        contract = requested;
        defaultProvider = "nixpkgs";
        allowedFields = {
          nixpkgs = ["provider" "version"];
          resolved = ["provider" "pkg"];
        };
        requiredFields.resolved = ["pkg"];
      };
      version = contract.optionalString parsed.fail "version" (parsed.spec.version or null);
      derivation =
        if parsed.provider == "resolved"
        then parsed.spec.pkg
        else select version;
    in
      if derivation == null
      then parsed.fail "nixpkgs does not provide requested Node.js ${version}"
      else
        contract.result {
          language = "node";
          default = packageSet.nodejs;
          pkg = derivation;
          provider = parsed.provider;
          fail = parsed.fail;
          tools.node = derivation;
          build = {
            npm = packageSet.buildNpmPackage.override {nodejs = derivation;};
          };
        };
  in {
    inherit toolchainFor;
  };
in {
  toolchainFor =
    if pkgs == null
    then _: throw "node-toolchain: toolchainFor requires a package set"
    else (resolverFor pkgs).toolchainFor;

  overlay = final: prev: {
    toolchains =
      (prev.toolchains or {})
      // {
        node = (resolverFor final).toolchainFor;
      };
  };
}

{pkgs ? null}: let
  contract = import ../toolchain-contract.nix;

  resolverFor = packageSet: let
    select = version:
      if version == null || packageSet.deno.version == version
      then packageSet.deno
      else null;
    toolchainFor = requested: let
      parsed = contract.parse {
        language = "deno";
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
      then parsed.fail "nixpkgs does not provide requested Deno ${version}"
      else
        contract.result {
          language = "deno";
          default = packageSet.deno;
          pkg = derivation;
          provider = parsed.provider;
          fail = parsed.fail;
          tools.deno = derivation;
        };
  in {
    inherit toolchainFor;
  };
in {
  toolchainFor =
    if pkgs == null
    then _: throw "deno-toolchain: toolchainFor requires a package set"
    else (resolverFor pkgs).toolchainFor;

  overlay = final: prev: {
    toolchains =
      (prev.toolchains or {})
      // {
        deno = (resolverFor final).toolchainFor;
      };
  };
}

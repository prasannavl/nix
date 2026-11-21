{pkgs ? null}: let
  contract = import ../toolchain-contract.nix;

  resolverFor = packageSet: let
    select = version:
      if version == null
      then packageSet.python3
      else let
        parts = builtins.splitVersion version;
        minor =
          if builtins.length parts >= 2
          then builtins.elemAt parts 0 + builtins.elemAt parts 1
          else null;
        attr =
          if minor == null
          then null
          else "python${minor}";
        candidate =
          if attr == null
          then null
          else contract.attrOrNull packageSet attr;
        full = builtins.length parts >= 3;
      in
        if candidate == null
        then null
        else if builtins.length parts == 2 || (full && candidate.version == version)
        then candidate
        else null;
    toolchainFor = requested: let
      parsed = contract.parse {
        language = "python";
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
      then parsed.fail "nixpkgs does not provide requested Python ${version}"
      else if !(derivation ? pkgs)
      then parsed.fail "selected Python must expose its package set"
      else
        contract.result {
          language = "python";
          default = packageSet.python3;
          pkg = derivation;
          provider = parsed.provider;
          fail = parsed.fail;
          tools.python = derivation;
          build = {
            pkgs = derivation.pkgs;
            pkg = derivation.pkgs.buildPythonPackage;
            app = derivation.pkgs.buildPythonApplication;
          };
        };
  in {
    inherit toolchainFor;
  };
in {
  toolchainFor =
    if pkgs == null
    then _: throw "python-toolchain: toolchainFor requires a package set"
    else (resolverFor pkgs).toolchainFor;

  overlay = final: prev: {
    toolchains =
      (prev.toolchains or {})
      // {
        python = (resolverFor final).toolchainFor;
      };
  };
}

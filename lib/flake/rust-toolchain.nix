# Optional per-capsule contract: null preserves the current nixpkgs/Crane
# defaults. Otherwise pass { provider = ...; } to craneLibFor/toolchainFor.
# toolchainFor resolves one coherent { craneLib; toolPkgs; id; custom; ... }
# record; validateBuildAttrs must run before certifying helper-built artifacts.
# Provider inputs must already be pinned by the caller; this module never fetches
# a flake or runs rustup. Fenix is the preferred external provider. The resolved
# adapter accepts a pre-resolved immutable Nix derivation, not a rustup directory.
{
  pkgs ? null,
  inputs ? {},
  # Adapter injection keeps the contract provider-agnostic. An adapter receives
  # the contract and returns one derivation containing the requested components.
  providers ? {},
}: let
  fail = message: throw "rust-toolchain: ${message}";
  requireInput = name:
    inputs.${name} or (fail "selected provider requires pinned input `${name}`");
  system = pkgs.stdenv.buildPlatform.system;
  isDerivation = value:
    builtins.isAttrs value && (value.type or null) == "derivation";
  bundle = packages:
    pkgs.symlinkJoin {
      name = "rust-toolchain";
      paths = [packages.rustc packages.cargo packages.clippy packages.rustfmt];
    };
  adapters =
    {
      nixpkgs-rustc = spec: bundle (spec.pkgs or pkgs);
      pinned-nixpkgs = spec: let
        pinned = requireInput (spec.input or "rust-nixpkgs");
        packages = import pinned {inherit system;};
      in
        bundle packages;
      fenix = spec: let
        packages = (requireInput (spec.input or "fenix")).packages.${system};
        profiles = {
          minimal = "minimalToolchain";
          default = "defaultToolchain";
          complete = "completeToolchain";
        };
        profile = spec.profile or "default";
        profileAttr = profiles.${profile} or (fail "unknown fenix profile `${profile}`; expected minimal, default or complete");
        channel = spec.channel or "stable";
        channelPackages = packages.${channel} or (fail "fenix has no `${channel}` channel in the pinned input; use stable/beta/latest or toolchainFile");
      in
        if spec ? toolchainFile
        then
          packages.fromToolchainFile {
            file = spec.toolchainFile;
            sha256 = spec.sha256 or (fail "fenix toolchainFile requires an explicit manifest sha256 (no evaluation-time discovery)");
          }
        else if profile == "minimal"
        then
          packages.combine [
            channelPackages.minimalToolchain
            channelPackages.clippy
            channelPackages.rustfmt
          ]
        else channelPackages.${profileAttr};
      oxalica = spec: let
        input = requireInput (spec.input or "rust-overlay");
        packages = pkgs.extend input.overlays.default;
      in
        if spec ? toolchainFile
        then packages.rust-bin.fromRustupToolchainFile spec.toolchainFile
        else fail "oxalica requires toolchainFile; use the pinned overlay's toolchain-file adapter";
      resolved = spec: spec.derivation or (fail "resolved provider requires `derivation`");
    }
    // providers;
  # Honor the effective caller library, including later overlay overrides.
  baseCraneLib =
    pkgs.craneLib or (
      if inputs ? crane
      then inputs.crane.mkLib pkgs
      else null
    );
  platformIdentity = platform: {
    system = platform.system;
    config = platform.config or platform.system;
  };
  nativeStdenv = stdenv:
    platformIdentity stdenv.buildPlatform
    == platformIdentity (stdenv.hostPlatform or stdenv.buildPlatform);
  compilerOverrides = attrs: let
    reserved = ["RUSTC" "RUSTDOC" "RUSTC_WRAPPER" "RUSTC_WORKSPACE_WRAPPER" "CARGO_BUILD_RUSTC" "CARGO_BUILD_RUSTC_WRAPPER" "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER" "CARGO_BUILD_RUSTDOC"];
  in
    builtins.filter (name: builtins.hasAttr name attrs || builtins.hasAttr name (attrs.env or {})) reserved;
  toolchainFor = contract:
    if pkgs == null
    then fail "toolchainFor requires a package set; bind `pkgs` or use the overlay methods"
    else let
      spec =
        if contract == null
        then {}
        else if builtins.isAttrs contract && !isDerivation contract
        then contract
        else fail "expected null or a toolchain contract attrset (use provider = resolved for a derivation)";
      provider = spec.provider or "nixpkgs-rustc";
      allowedFields = {
        nixpkgs-rustc = ["provider" "pkgs"];
        pinned-nixpkgs = ["provider" "input"];
        fenix = ["provider" "input" "toolchainFile" "sha256" "channel" "profile"];
        oxalica = ["provider" "input" "toolchainFile"];
        resolved = ["provider" "derivation"];
      };
      unknownFields = builtins.removeAttrs spec (allowedFields.${provider} or []);
      validSpec =
        if !(builtins.hasAttr provider providers) && unknownFields != {} && builtins.hasAttr provider allowedFields
        then fail "unsupported fields for `${provider}`: ${builtins.concatStringsSep ", " (builtins.attrNames unknownFields)}; encode custom components/targets in toolchainFile or use resolved"
        else if provider == "fenix" && spec ? toolchainFile && (spec ? channel || spec ? profile)
        then fail "fenix toolchainFile cannot be combined with channel/profile"
        else if provider == "fenix" && spec ? sha256 && !(spec ? toolchainFile)
        then fail "fenix sha256 is only meaningful with toolchainFile"
        else if spec ? toolchainFile && !(builtins.isPath spec.toolchainFile)
        then fail "toolchainFile must be an evaluator-visible Nix path (never a derivation/IFD)"
        else if spec ? toolchainFile
        then let
          # Oxalica also accepts legacy plain-text rust-toolchain files.
          fileContents = builtins.readFile spec.toolchainFile;
          isToml =
            builtins.match ".*\\.toml" (toString spec.toolchainFile)
            != null
            || builtins.match ".*\\[.*" fileContents != null;
          fileContract =
            if isToml
            then (builtins.fromTOML fileContents).toolchain or {}
            else {};
          components = fileContract.components or [];
        in
          if
            (fileContract.profile or "default")
            == "minimal"
            && !(builtins.elem "clippy" components && builtins.elem "rustfmt" components)
          then fail "minimal toolchainFile must declare clippy and rustfmt; package operations require both"
          else true
        else true;
      defaultSelection = provider == "nixpkgs-rustc" && !(spec ? pkgs) && !(providers ? nixpkgs-rustc);
      buildPlatform = pkgs.stdenv.buildPlatform;
      hostPlatform = pkgs.stdenv.hostPlatform or buildPlatform;
      alternatePkgs = spec.pkgs or pkgs;
      alternateBuildPlatform = alternatePkgs.stdenv.buildPlatform or buildPlatform;
      alternateHostPlatform = alternatePkgs.stdenv.hostPlatform or alternateBuildPlatform;
      derivation = builtins.seq validSpec (
        if defaultSelection
        then null
        else if
          platformIdentity hostPlatform
          != platformIdentity buildPlatform
          || platformIdentity alternateHostPlatform != platformIdentity alternateBuildPlatform
          || platformIdentity alternateBuildPlatform != platformIdentity buildPlatform
        then fail "custom toolchains under Nix cross compilation require a spliced Crane toolchain; this adapter currently supports native package sets only"
        else if provider == "rustup"
        then fail "rustup is development-only; production requires an immutable pre-resolved derivation"
        else if !(builtins.hasAttr provider adapters)
        then fail "unknown provider `${provider}`"
        else let
          selected = adapters.${provider} spec;
        in
          if !isDerivation selected
          then fail "provider `${provider}` must return a toolchain derivation"
          else if (selected.pname or null) == "rustup" || builtins.match "rustup(-.*)?" (selected.name or "") != null
          then fail "rustup is a mutable development runner, not a pre-resolved production toolchain"
          else selected
      );
      # Ask Crane's scope for its actual bound package set/tools. Reapplying its
      # selector to the caller would conceal a library built from cross pkgs.
      libraryContext =
        if baseCraneLib == null
        then {
          pkgs = pkgs;
          tools = pkgs;
          stdenv = pkgs.stdenv;
        }
        else if baseCraneLib ? callPackage
        then
          baseCraneLib.callPackage ({
            pkgs,
            cargo,
            rustc,
            clippy,
            rustfmt,
            stdenvSelector,
          }: {
            pkgs = pkgs;
            tools = {inherit cargo rustc clippy rustfmt;};
            stdenv = stdenvSelector pkgs;
          }) {}
        else {
          pkgs = pkgs;
          tools = baseCraneLib;
          stdenv = (baseCraneLib.stdenvSelector or (p: p.stdenv)) pkgs;
        };
      # Resolve compiler, library, operation tools and identity once.
      operationTools = builtins.listToAttrs (map (name: {
        name = name;
        value =
          if derivation != null
          then derivation
          else libraryContext.tools.${name} or pkgs.${name};
      }) ["cargo" "rustc" "clippy" "rustfmt"]);
      toolPkgs = pkgs // operationTools;
      # Default spliced Nix-cross libraries remain supported. Native alternate
      # bindings and explicitly overridden compilers are custom contracts.
      custom =
        derivation
        != null
        || (
          (nativeStdenv pkgs.stdenv || (baseCraneLib != null && (baseCraneLib ? rustc || baseCraneLib ? cargo)))
          && (toString operationTools.rustc != toString pkgs.rustc || toString operationTools.cargo != toString pkgs.cargo)
        );
      selectedCraneLib =
        if derivation == null
        then baseCraneLib
        else if baseCraneLib == null
        then fail "custom toolchain requires the pinned crane input (or pkgs.craneLib)"
        else baseCraneLib.overrideToolchain derivation;
      effectiveStdenv = libraryContext.stdenv;
      platformGuard =
        if !custom
        then true
        else if
          !nativeStdenv effectiveStdenv
          || platformIdentity effectiveStdenv.buildPlatform != platformIdentity pkgs.stdenv.buildPlatform
        then fail "custom toolchains require a native effective Crane stdenv on the caller build platform"
        else if derivation != null && derivation ? system && derivation.system != system
        then fail "selected toolchain must run on the caller build platform `${system}`"
        else true;
      # Labels/providers do not affect identity. Explicit and pre-overridden
      # selections of the same Cargo/rustc paths must accept each other's layers.
      id = "rust:${operationTools.rustc}:${operationTools.cargo}";
      validateBuildAttrs = attrs: let
        overrides = compilerOverrides attrs;
        stdenvOverride = attrs.stdenv or effectiveStdenv;
        buildStdenv =
          if builtins.isFunction stdenvOverride
          then stdenvOverride libraryContext.pkgs
          else stdenvOverride;
      in
        if overrides != []
        then fail "compiler-changing build/check attributes are unsupported: ${builtins.concatStringsSep ", " overrides}; select the compiler through `toolchain` instead"
        else if
          custom
          && (!nativeStdenv buildStdenv
            || platformIdentity buildStdenv.buildPlatform != platformIdentity pkgs.stdenv.buildPlatform)
        then fail "custom toolchains require a native effective build stdenv; cross stdenv overrides are unsupported"
        else true;
    in
      builtins.seq platformGuard {
        inherit provider derivation id toolPkgs custom validateBuildAttrs;
        craneLib = selectedCraneLib;
      };
  craneLibFor = contract: (toolchainFor contract).craneLib;
in {
  inherit toolchainFor craneLibFor;
  # Both root and fallback compositions import this exact overlay seam.
  overlay = final: prev: let
    resolver = import ./rust-toolchain.nix {
      inherit inputs providers;
      pkgs = final;
    };
  in {
    # Bootstrap independently of the resolver to avoid a self-reference. Method
    # selection uses final, so later rustc/Crane overlays remain composable.
    craneLib =
      if inputs ? crane
      then inputs.crane.mkLib final
      else prev.craneLib or null;
    inherit (resolver) craneLibFor;
    rustToolchainFor = resolver.toolchainFor;
  };
}

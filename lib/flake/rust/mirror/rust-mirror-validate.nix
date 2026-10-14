# Trusted generator-side evaluator, not revision-owned source authority.
# Exercise native derivation identities and source selections only. No builds,
# NixOS module application, alternate systems or higher-order caller coverage.
{
  src,
  lock,
  sources,
}: let
  system = builtins.currentSystem;
  nodes = lock.nodes;
  makeInput = name: let
    node = nodes.${name};
    path = /. + sources.${name};
    dependencies = builtins.mapAttrs (_: makeInput) (node.inputs or {});
    metadata = node.locked // {outPath = path;};
    outputs = (import (path + "/flake.nix")).outputs (dependencies // {self = result;});
    result =
      if !(node.flake or true)
      then metadata
      else
        outputs
        // metadata
        // {
          inputs = dependencies;
          sourceInfo = metadata;
          _type = "flake";
        };
  in
    result;
  roots = builtins.mapAttrs (_: makeInput) nodes.${lock.root}.inputs;
  # Keep the real cached flake-utils implementation, but bound its default
  # system list for this validation invocation only; generated defaults stay put.
  inputs =
    roots
    // {
      flake-utils =
        roots.flake-utils
        // {
          lib = roots.flake-utils.lib // {defaultSystems = [system];};
        };
    };
  outputs = (import (src + "/flake.nix")).outputs inputs;
  library = outputs.lib.${system};
  identity = drv: {
    inherit (drv) drvPath outputName outPath;
  };
  identities = attrs: builtins.mapAttrs (_: identity) attrs;
  evidence = {
    inherit system;
    packages = identities outputs.packages.${system};
    checks = identities (outputs.checks.${system} or {});
    apps =
      builtins.mapAttrs (_: app: {inherit (app) type program;})
      (outputs.apps.${system} or {});
    depsBase = identity library.depsBase;
    workspaceSrc = identity library.workspaceSrc;
    workspaceInput = toString library.workspaceSrc.src;
    component = library.component;
    devShell = identity outputs.devShells.${system}.default;
    formatter = identity outputs.formatter.${system};
  };
in
  builtins.deepSeq evidence (evidence // {validated = true;})

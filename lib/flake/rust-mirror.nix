# A pristine, explicitly scoped source selection, never a package registry or
# compiler/artifact certificate. Original definitions own all build semantics.
{
  inputs,
  src,
  memberDirs,
  primaryMember,
  systems ? inputs.flake-utils.lib.defaultSystems,
  pkgsForSystem ? null,
}: let
  helper = import ./pkg-helper.nix;
  stack = import ./stack/package.nix;
  scoped = helper.forRustSource {inherit src memberDirs;};
  topology = scoped.rustPlan {src = src;};
  guard =
    if !topology.supported || !(builtins.elem primaryMember memberDirs)
    then throw "rust-mirror: unsupported source scope or primary member"
    else true;
  members =
    map (dir: {
      inherit dir;
      name = (builtins.fromTOML (builtins.readFile (src + "/${dir}/Cargo.toml"))).package.name;
      builder = import ./rust-export.nix {
        inherit src memberDirs;
        packageFile = src + "/${dir}/default.nix";
      };
    })
    memberDirs;
  names = map (p: p.name) members;
  namesGuard =
    if builtins.length (inputs.nixpkgs.lib.unique names) != builtins.length names
    then throw "rust-mirror: duplicate Cargo package names"
    else true;
  primary = builtins.head (builtins.filter (p: p.dir == primaryMember) members);
  packageFor = {
    pkgs,
    packageFile,
  }:
    (import ./rust-export.nix {inherit src memberDirs packageFile;}).mkPackage {pkgs = pkgs;};
  primaryOutputs = stack.mkFlakeOutputs (src + "/${primaryMember}/default.nix") (inputs
    // {
      inherit systems packageFor pkgsForSystem;
      libExports = {
        pkgs,
        build,
        ...
      }: let
        # The helper retains the actual library's bound writer; never reselect
        # the caller's default compiler/library for a recipe-specific build.
        operationContext = build.passthru.__rustOperationContext;
        compiler = build.passthru.memberLayer;
        ownedShell = build.passthru.devShell or null;
        operationTools = build.passthru.actualOperationTools;
        rootManifest = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
        projectedManifest = operationContext.writeTOML "mirror-workspace-Cargo.toml" (rootManifest
          // {
            workspace = rootManifest.workspace // {members = topology.plan.closureDirs.${primaryMember};};
          });
        workspaceSrc =
          pkgs.runCommandLocal "rust-mirror-workspace-source" {
            src = build.src;
            projectedManifest = projectedManifest;
          } ''
            mkdir -p "$out"
            cp -a "$src"/. "$out"/
            chmod u+w "$out" "$out/Cargo.toml"
            cp "$projectedManifest" "$out/Cargo.toml"
          '';
      in {
        mkPackage = primary.builder.mkPackage;
        depsBase = build.passthru.depsBase;
        # An explicit writable workspace can be copied from this projected source;
        # entering a shell never mutates the pristine mirror/root manifest.
        workspaceSrc = workspaceSrc;
        component = {
          id = builtins.hashString "sha256" (builtins.toJSON (builtins.sort builtins.lessThan memberDirs));
          memberDirs = memberDirs;
          packages = names;
        };
        packages = builtins.listToAttrs (map (p: {
            name = p.name;
            value = {mkPackage = p.builder.mkPackage;};
          })
          members);
        # Nix formatter only; Cargo fmt stays the package-owned fmt check/app.
        formatter = pkgs.alejandra;
        # Only inputs are inherited from the package-owned shell. Its hook is
        # intentionally unsupported: mkShell otherwise concatenates inputsFrom
        # hooks even when our own shellHook is empty. No mirror/root rewrites or
        # other package shell actions may run merely by entering this shell.
        devShell = pkgs.mkShell (operationContext.env
          // {
            inputsFrom =
              map (drv: builtins.removeAttrs drv ["shellHook"])
              ([compiler] ++ pkgs.lib.optional (ownedShell != null) ownedShell);
            packages = builtins.attrValues operationTools;
            shellHook = "";
          });
      };
    });
  memberOutputs =
    map (p: {
      package = p;
      outputs =
        if p.dir == primaryMember
        then primaryOutputs
        else
          stack.mkFlakeOutputs (src + "/${p.dir}/default.nix") (inputs
            // {
              inherit systems packageFor pkgsForSystem;
            });
    })
    members;
  add = acc: entry: let
    outputs = entry.outputs;
    name = entry.package.name;
    withNamed =
      builtins.foldl' (a: system: let
        packageValues = {${name} = outputs.packages.${system}.default;};
        namespace = attrs:
          builtins.listToAttrs (map (key: {
            name = "${name}-${key}";
            value = attrs.${key};
          }) (builtins.attrNames (builtins.removeAttrs attrs ["default"])));
        additions = {
          packages = packageValues;
          checks = namespace (outputs.checks.${system} or {});
          apps = namespace (outputs.apps.${system} or {});
        };
      in
        builtins.foldl' (
          result: kind: let
            existing = result.${kind}.${system} or {};
            added = additions.${kind};
          in
            if builtins.intersectAttrs existing added != {}
            then throw "rust-mirror: overlapping ${kind} exports for ${name}"
            else result // {${kind} = (result.${kind} or {}) // {${system} = existing // added;};}
        )
        a ["packages" "checks" "apps"])
      acc
      systems;
    modules =
      if entry.package.dir == primaryMember
      then {}
      else outputs.nixosModules or {};
  in
    if builtins.intersectAttrs (acc.nixosModules or {}) modules != {}
    then throw "rust-mirror: overlapping module exports require explicit ownership"
    else
      withNamed
      // inputs.nixpkgs.lib.optionalAttrs (modules != {}) {
        nixosModules = (acc.nixosModules or {}) // modules;
      };
  combined = builtins.foldl' add primaryOutputs memberOutputs;
in
  builtins.seq guard (builtins.seq namesGuard (combined
    // {
      formatter = builtins.listToAttrs (map (system: {
          name = system;
          value = primaryOutputs.lib.${system}.formatter;
        })
        systems);
      devShells = builtins.listToAttrs (map (system: {
          name = system;
          value.default = primaryOutputs.lib.${system}.devShell;
        })
        systems);
    }))

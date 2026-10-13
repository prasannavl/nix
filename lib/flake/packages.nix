{
  pkgs,
  stack ? import ./stack/package.nix,
  pkgHelper ? stack.pkg,
  # Inert until explicitly supplied; root composition does not enable adoption.
  externalPackagesFor ? _system: {},
}: let
  manifest = import ../../pkgs/manifest.nix;
  entries =
    builtins.mapAttrs (
      _: entry:
        if builtins.isPath entry
        then {path = entry;}
        else entry
    )
    manifest.packages;
  allowedEntryFields = ["aliases" "apps" "args" "path" "rootApp" "toolingPackages"];
  unknownEntryFields = builtins.concatMap (
    name:
      map (field: "${name}.${field}") (
        builtins.filter (
          field: !(builtins.elem field allowedEntryFields)
        ) (builtins.attrNames entries.${name})
      )
  ) (builtins.attrNames entries);
  validatedEntries =
    if unknownEntryFields == []
    then entries
    else throw "pkgs/manifest.nix: unsupported package fields: ${builtins.concatStringsSep ", " unknownEntryFields}";
  resolveSelectors = owner: selectors:
    builtins.mapAttrs (
      name: path:
        pkgs.lib.attrByPath path
        (throw "pkgs/manifest.nix: selector for `${name}` does not resolve")
        owner
    )
    selectors;
  stackArgsFor = path: let
    args = builtins.functionArgs (import path);
  in
    if args ? stack
    then {stack = stack;}
    else {};
  external = externalPackagesFor pkgs.stdenv.hostPlatform.system;
  externalGuard =
    if !builtins.isAttrs external
    then throw "externalPackagesFor: expected an attribute set"
    else if builtins.any (name: !(validatedEntries ? ${name})) (builtins.attrNames external)
    then throw "externalPackagesFor: overrides must name canonical manifest packages"
    else true;
  canonicalPackages = builtins.seq externalGuard (
    builtins.mapAttrs (name: entry: let
      packageArgs =
        if entry ? args
        then entry.args canonicalPackages
        else {};
      candidate = external.${name} or null;
      replacement =
        if builtins.isFunction candidate
        then candidate {inherit pkgs pkgHelper stack packageArgs;}
        else candidate;
    in
      if external ? ${name}
      then
        if pkgs.lib.isDerivation replacement
        then replacement
        else throw "externalPackagesFor: `${name}` must provide a derivation or constructor"
      else pkgs.callPackage entry.path ((stackArgsFor entry.path) // packageArgs))
    validatedEntries
  );
  packageAliases = builtins.foldl' (
    aliases: name:
      aliases
      // builtins.listToAttrs (
        map (alias: {
          name = alias;
          value = canonicalPackages.${name};
        }) (validatedEntries.${name}.aliases or [])
      )
  ) {} (builtins.attrNames validatedEntries);
  toolingPackages = builtins.foldl' (
    tools: name:
      tools
      // resolveSelectors
      canonicalPackages.${name}
      (validatedEntries.${name}.toolingPackages or {})
  ) {} (builtins.attrNames validatedEntries);
  rootApps = builtins.foldl' (
    apps: name:
      apps
      // pkgs.lib.optionalAttrs (validatedEntries.${name}.rootApp or false) {
        ${name} = canonicalPackages.${name};
      }
      // resolveSelectors canonicalPackages.${name} (validatedEntries.${name}.apps or {})
  ) {} (builtins.attrNames validatedEntries);
  packages = canonicalPackages // packageAliases;
in {
  packages = packages;
  stdPackages = packages // toolingPackages;
  rootApps = rootApps;
}

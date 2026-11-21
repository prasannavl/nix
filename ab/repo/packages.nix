{
  ab,
  externalPackagesFor ? _system: {},
  manifest,
  pkgs,
  validation,
}: let
  inherit (validation.mk "repository package manifest") mergeUniqueAttrs;
  entries =
    builtins.mapAttrs (
      _: entry:
        if builtins.isPath entry
        then {path = entry;}
        else entry
    )
    manifest.packages;
  allowedEntryFields = ["aliases" "apps" "path" "rootApp" "toolingPackages"];
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
    else throw "repository package manifest: unsupported package fields: ${builtins.concatStringsSep ", " unknownEntryFields}";
  resolveSelectors = owner: selectors:
    builtins.mapAttrs (
      name: path:
        pkgs.lib.attrByPath path
        (throw "repository package manifest: selector for `${name}` does not resolve")
        owner
    )
    selectors;
  external = externalPackagesFor pkgs.stdenv.hostPlatform.system;
  externalGuard =
    if !builtins.isAttrs external
    then throw "externalPackagesFor: expected an attribute set"
    else if builtins.any (name: !(validatedEntries ? ${name})) (builtins.attrNames external)
    then throw "externalPackagesFor: overrides must name canonical manifest packages"
    else true;
  canonicalPackages = builtins.seq externalGuard (
    builtins.mapAttrs (name: entry: let
      candidate = external.${name} or null;
      replacement =
        if builtins.isFunction candidate
        then candidate {inherit ab pkgs;}
        else candidate;
    in
      if external ? ${name}
      then
        if pkgs.lib.isDerivation replacement
        then replacement
        else throw "externalPackagesFor: `${name}` must provide a derivation or constructor"
      else pkgs.callPackage entry.path {})
    validatedEntries
  );
  packageAliases = mergeUniqueAttrs "package aliases" (
    builtins.concatMap (
      name:
        map (alias: {${alias} = canonicalPackages.${name};})
        (validatedEntries.${name}.aliases or [])
    ) (builtins.attrNames validatedEntries)
  );
  toolingPackages = mergeUniqueAttrs "tooling packages" (
    map (
      name:
        resolveSelectors canonicalPackages.${name}
        (validatedEntries.${name}.toolingPackages or {})
    ) (builtins.attrNames validatedEntries)
  );
  rootApps = mergeUniqueAttrs "apps" (
    builtins.concatMap (name: [
      (pkgs.lib.optionalAttrs (validatedEntries.${name}.rootApp or false) {
        ${name} = canonicalPackages.${name};
      })
      (resolveSelectors canonicalPackages.${name} (validatedEntries.${name}.apps or {}))
    ]) (builtins.attrNames validatedEntries)
  );
  packages = mergeUniqueAttrs "packages" [canonicalPackages packageAliases];
in {
  manifest = validatedEntries;
  inherit canonicalPackages packageAliases packages rootApps toolingPackages;
  stdPackages = mergeUniqueAttrs "standard packages" [packages toolingPackages];
}

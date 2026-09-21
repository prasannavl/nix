{pkgs}: let
  lib = pkgs.lib;
  runner = ../postgres-extensions/runner.py;
  numericVersion = version:
    builtins.isString version
    && builtins.match "[0-9]+([.][0-9]+)+" version != null;
  normalizeUpgradeFrom = name: target: upgradeFrom:
    if !builtins.isList upgradeFrom || upgradeFrom == [] || !builtins.all numericVersion upgradeFrom
    then throw "PostgreSQL extension ${name} upgradeFrom must contain one or more numeric versions"
    else if upgradeFrom != [] && !lib.all (pair: lib.versionOlder pair.fst pair.snd) (lib.zipLists upgradeFrom (lib.tail upgradeFrom))
    then throw "PostgreSQL extension ${name} upgradeFrom must be strictly increasing"
    else if !builtins.all (version: lib.versionOlder version target) upgradeFrom
    then throw "PostgreSQL extension ${name} upgradeFrom versions must be older than its target"
    else upgradeFrom;
  normalizeExtension = name: targetOverride: spec: let
    structured = builtins.isAttrs spec;
    allowedKeys =
      if targetOverride != null
      then ["upgradeFrom"]
      else ["target" "upgradeFrom"];
    target =
      if targetOverride != null
      then targetOverride
      else if structured
      then spec.target or null
      else spec;
    upgradeFrom =
      if structured && spec ? upgradeFrom
      then normalizeUpgradeFrom name target spec.upgradeFrom
      else null;
  in
    if builtins.match "[a-z][a-z0-9_]*" name == null
    then throw "Invalid PostgreSQL extension name: ${name}"
    else if structured && !builtins.all (key: builtins.elem key allowedKeys) (builtins.attrNames spec)
    then throw "PostgreSQL extension ${name} has unsupported policy fields"
    else if !numericVersion target
    then throw "PostgreSQL extension ${name} target must be numeric"
    else if targetOverride != null && structured && spec ? target
    then throw "TimescaleDB target comes from imageTag and must not be duplicated"
    else
      {target = target;}
      // lib.optionalAttrs (upgradeFrom != null) {upgradeFrom = upgradeFrom;};
  mkTimescalePolicy = {
    imageTag,
    extensions,
  }: let
    imageVersions = builtins.match "pg([0-9]+)[.]([0-9]+)-ts([0-9]+[.][0-9]+[.][0-9]+)" imageTag;
    timescale = extensions.timescaledb or {};
    timescaleTarget =
      if imageVersions == null
      then null
      else builtins.elemAt imageVersions 2;
    normalized = lib.mapAttrs (name: normalizeExtension name null) (builtins.removeAttrs extensions ["timescaledb"]);
    timescalePolicy = normalizeExtension "timescaledb" timescaleTarget timescale;
  in
    if imageVersions == null
    then throw "PostgreSQL image tag must be exactly pgX.Y-tsA.B.C"
    else if !builtins.isAttrs extensions || !builtins.isAttrs timescale
    then throw "PostgreSQL extensions and timescaledb policy must be attribute sets"
    else {
      image = "docker.io/timescale/timescaledb-ha:${imageTag}";
      postgresMajor = lib.toInt (builtins.elemAt imageVersions 0);
      extensions = normalized // {timescaledb = timescalePolicy;};
    };
in {
  inherit mkTimescalePolicy;

  mkRunner = {
    name,
    container,
    policy,
  }: let
    policyFile = pkgs.writeText "${name}-policy.json" (builtins.toJSON policy);
  in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.python3 pkgs.podman];
      text = ''
        exec python3 ${runner} --policy ${policyFile} \
          --container ${lib.escapeShellArg container} "$@"
      '';
    };
}

let
  mkScope = {
    base,
    scope ? null,
    scopeSeparator ? "-",
  }: let
    scopeBase = base;
    hasScope = scope != null && scope != "";
    scopedName = name:
      if !hasScope
      then name
      else let
        parts = builtins.match "(.*/)?([^/]+)" name;
        dir = builtins.elemAt parts 0;
        basename = builtins.elemAt parts 1;
        prefix =
          if dir == null
          then ""
          else dir;
      in "${prefix}${scope}${scopeSeparator}${basename}";
  in rec {
    base = scopeBase;
    secretScope = scope;
    scopedFileName = scopedName;
    unscopedFile = name: "${scopeBase}/${name}";
    file = name: unscopedFile (scopedName name);
    key = name: file "${name}.key.age";
  };
in {
  inherit mkScope;

  mkStack = {
    base,
    scope ? null,
  }: let
    paths = mkScope {
      base = base;
      scope = scope;
    };
  in
    paths
    // rec {
      service = name: paths.unscopedFile "services/${name}";
      serviceFile = serviceName: fileName: "${service serviceName}/${paths.scopedFileName fileName}";
      serviceKey = serviceName: secretName: serviceFile serviceName "${secretName}.key.age";
      key = serviceKey;
      ext = provider: paths.unscopedFile "ext/${provider}";
      extFile = provider: fileName: "${ext provider}/${paths.scopedFileName fileName}";
      extKey = provider: secretName: extFile provider "${secretName}.key.age";
    };

  mkGlobals = {
    path,
    base ? "data/secrets/globals",
  }: let
    scope = mkScope {
      base = base;
    };
    readRecipient = keyPath:
      builtins.replaceStrings ["\n"] [""] (builtins.readFile keyPath);
    machine = name: let
      publicKey = path + "/machine/${name}.key.pub";
    in {
      key = scope.file "machine/${name}.key.age";
      publicKey = publicKey;
      recipients = [(readRecipient publicKey)];
    };
  in
    scope
    // {
      machine = machine;
      machineIdentities = {
        machines,
        defaultAccess,
      }: let
        machineNames = builtins.attrNames machines;
        accessFor = name:
          machines.${name}.access or defaultAccess;
      in {
        recipients =
          builtins.listToAttrs
          (map (name: {
              name = name;
              value = (machine name).recipients;
            })
            machineNames);
        secrets =
          builtins.listToAttrs
          (map (name: {
              name = (machine name).key;
              value.publicKeys = accessFor name;
            })
            machineNames);
      };
    };
}

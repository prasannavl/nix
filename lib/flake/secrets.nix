let
  mkScope = {base}: let
    scopeBase = base;
  in rec {
    base = scopeBase;
    file = name: "${scopeBase}/${name}";
    key = name: file "${name}.key.age";
  };
in {
  inherit mkScope;

  mkStack = {base}: let
    scope = mkScope {
      base = base;
    };
  in
    scope
    // rec {
      service = name: scope.file "services/${name}";
      serviceFile = serviceName: fileName: "${service serviceName}/${fileName}";
      serviceKey = serviceName: secretName: serviceFile serviceName "${secretName}.key.age";
      key = serviceKey;
      ext = provider: scope.file "ext/${provider}";
      extFile = provider: fileName: "${ext provider}/${fileName}";
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
      recipients = [readRecipient publicKey];
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

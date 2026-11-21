{lib}: rec {
  mkSecretBackedClient = {
    config,
    authKeyFile,
    authKeySecretName ? "tailscale-auth-key",
    authKeyParameters ? {
      ephemeral = false;
      preauthorized = true;
    },
    port ? null,
    useRoutingFeatures ? "client",
    advertiseTags ? [],
    owner ? "root",
    group ? "root",
    mode ? "0400",
  }: {
    age.secrets.${authKeySecretName} = {
      file = authKeyFile;
      inherit owner group mode;
    };

    services.tailscale =
      {
        enable = true;
        authKeyFile = config.age.secrets.${authKeySecretName}.path;
        authKeyParameters = authKeyParameters;
        extraUpFlags =
          lib.optional (advertiseTags != [])
          "--advertise-tags=${lib.concatStringsSep "," advertiseTags}";
      }
      // lib.optionalAttrs (port != null) {
        port = port;
      }
      // lib.optionalAttrs (useRoutingFeatures != null) {
        useRoutingFeatures = useRoutingFeatures;
      };
  };

  mkOptionalAuthKeyClient = {
    config,
    keyName,
    secretsDir,
    secretFileName ? null,
    authKeyStoreName ? secretFileName,
    ...
  } @ args: let
    resolvedSecretFileName =
      if secretFileName != null
      then secretFileName
      else if keyName == null || keyName == ""
      then null
      else "${keyName}.key.age";
    resolvedAuthKeyStoreName =
      if authKeyStoreName != null
      then authKeyStoreName
      else resolvedSecretFileName;
    authKeyPath =
      if resolvedSecretFileName == null
      then null
      else secretsDir + "/${resolvedSecretFileName}";
  in
    if authKeyPath != null && builtins.pathExists authKeyPath
    then
      mkSecretBackedClient (
        builtins.removeAttrs args [
          "keyName"
          "secretsDir"
          "secretFileName"
          "authKeyStoreName"
        ]
        // {
          config = config;
          authKeyFile = builtins.path {
            path = authKeyPath;
            name = resolvedAuthKeyStoreName;
          };
        }
      )
    else {};
}

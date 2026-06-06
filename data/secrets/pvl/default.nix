{
  admins,
  machines,
}: let
  secrets = rec {
    base = "data/secrets/pvl";
    file = name: "${base}/${name}";
    service = name: "${base}/services/${name}";
    serviceFile = serviceName: fileName: "${service serviceName}/${fileName}";
    serviceKey = serviceName: secretName: serviceFile serviceName "${secretName}.key.age";
    key = serviceKey;
    ext = provider: "${base}/ext/${provider}";
    extFile = provider: fileName: "${ext provider}/${fileName}";
    extKey = provider: secretName: extFile provider "${secretName}.key.age";
  };
  serviceSecrets = import ./services.nix {
    inherit admins machines secrets;
  };
in
  serviceSecrets

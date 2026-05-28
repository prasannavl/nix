{users}: let
  concatMap = f: xs: builtins.concatLists (map f xs);
  listToAttrs = builtins.listToAttrs;
  mapAttrsToList = f: attrs:
    map (name: f name attrs.${name}) (builtins.attrNames attrs);
  mergeAttrs = attrs:
    builtins.foldl' (acc: value: acc // value) {} attrs;

  userSshKeys = user:
    if users ? ${user}
    then
      users.${
        user
      }.sshKeys
      or (
        if users.${user} ? sshKey
        then [users.${user}.sshKey]
        else []
      )
    else throw "Unknown user for Incus cert recipients: ${user}";

  normalizeCertificate = user: cert:
    if builtins.isString cert
    then {
      name = cert;
      projects = [];
      restricted = false;
    }
    else
      cert
      // {
        name = cert.name or user;
        projects = cert.projects or [];
        restricted = cert.restricted or ((cert.projects or []) != []);
      };

  mkCertificateEntry = {
    user,
    recipientUser,
    extraRecipients,
    root,
    publicDir,
    secretDir,
    keyType,
    days,
  }: cert: let
    normalized = normalizeCertificate user cert;
    name = normalized.name;
    projects = normalized.projects;
    restricted = normalized.restricted;
    type = normalized.type or "client";
    recipients = userSshKeys recipientUser ++ extraRecipients;
    publicCert = "${publicDir}/${name}.crt";
    keyAge = "${secretDir}/${name}.key.age";
    pfxAge = "${secretDir}/${name}.pfx.age";
  in {
    inherit days keyAge keyType name pfxAge projects publicCert recipients restricted type;
    inherit recipientUser user;
    ageSecrets = {
      "${keyAge}".publicKeys = recipients;
      "${pfxAge}".publicKeys = recipients;
    };
    generatorConfig = [
      {
        inherit days keyAge keyType name pfxAge projects publicCert recipients restricted type;
        inherit recipientUser user;
      }
    ];
    trustedCertificate = {
      inherit name projects restricted type;
      certificate = builtins.readFile (root + "/${publicCert}");
    };
  };

  mkIncusCertsForUser = {
    user,
    certificates ? [
      {
        name = user;
        projects = [];
        restricted = false;
      }
    ],
    recipientUser ? user,
    extraRecipients ? [],
    root ? ../..,
    publicDir ? "data/secrets/incus",
    secretDir ? "data/secrets/incus",
    keyType ? "ecdsa-p256",
    days ? 3650,
  }: let
    entries =
      map
      (mkCertificateEntry {
        inherit days extraRecipients keyType publicDir recipientUser root secretDir user;
      })
      certificates;
  in {
    inherit certificates entries recipientUser user;
    ageSecrets = mergeAttrs (map (entry: entry.ageSecrets) entries);
    generatorConfig = concatMap (entry: entry.generatorConfig) entries;
    trustedCertificates = map (entry: entry.trustedCertificate) entries;
    byName = listToAttrs (map (entry: {
        inherit (entry) name;
        value = entry;
      })
      entries);
  };

  mergeIncusCertGroups = groups: let
    groupList = mapAttrsToList (_: value: value) groups;
    entries = concatMap (group: group.entries) groupList;
  in {
    inherit entries;
    ageSecrets = mergeAttrs (map (group: group.ageSecrets) groupList);
    generatorConfig = concatMap (group: group.generatorConfig) groupList;
    trustedCertificates = concatMap (group: group.trustedCertificates) groupList;
    byName = listToAttrs (map (entry: {
        inherit (entry) name;
        value = entry;
      })
      entries);
  };
in {
  inherit mergeIncusCertGroups mkIncusCertsForUser;
}

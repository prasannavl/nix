{users}: let
  mergeAttrs = attrs:
    builtins.foldl' (acc: value: acc // value) {} attrs;

  unique = values:
    builtins.foldl'
    (acc: value:
      if builtins.elem value acc
      then acc
      else acc ++ [value])
    []
    values;

  userSshKeys = user:
    if users ? ${user}
    then users.${user}.sshKeys or []
    else throw "Unknown user for Incus cert recipients: ${user}";

  mkUserCertWithKeys = {
    user,
    projects,
    cert,
    key,
    pfx,
    name ? user,
    recipientUser ? user,
    extraRecipients ? [],
    extraKeyRecipients ? [],
    keyType ? "ecdsa-p256",
    days ? 3650,
  }: let
    pfxRecipients = userSshKeys recipientUser ++ extraRecipients;
    keyRecipients = pfxRecipients ++ extraKeyRecipients;
  in {
    inherit cert days key keyRecipients keyType name pfx pfxRecipients projects recipientUser user;
    recipients = pfxRecipients;
    ageSecrets = {
      "${key}".publicKeys = keyRecipients;
      "${pfx}".publicKeys = pfxRecipients;
    };
    generatorConfig = [
      {
        inherit days keyRecipients keyType name pfxRecipients projects recipientUser user;
        recipients = pfxRecipients;
        publicCert = cert;
        keyAge = key;
        pfxAge = pfx;
      }
    ];
  };

  mergeUserCerts = certs: {
    ageSecrets = mergeAttrs (map (cert: cert.ageSecrets) certs);
    generatorConfig = builtins.concatLists (map (cert: cert.generatorConfig) certs);
  };

  certFiles = root: certs:
    map (cert: root + "/${cert.cert}") certs;

  certFilesByName = root: certsByName:
    builtins.mapAttrs (_user: cert: root + "/${cert.cert}") certsByName;

  usersFromProjects = projects:
    unique (
      builtins.concatLists (
        map (project: projects.${project}.userCerts or [])
        (builtins.attrNames projects)
      )
    );

  projectsForUser = projects: user:
    builtins.filter
    (project: builtins.elem user (projects.${project}.userCerts or []))
    (builtins.attrNames projects);

  certFilesForUsers = root: certsByName: users:
    certFiles root (map (user: certsByName.${user}) users);

  mkUserCertsForProjects = {
    root,
    projects,
    mkUserCert,
  }: let
    projectUsers = usersFromProjects projects;
    certsByName =
      builtins.listToAttrs
      (map (user: {
          name = user;
          value = mkUserCert {
            user = user;
            projects = projectsForUser projects user;
          };
        })
        projectUsers);
    certs = map (user: certsByName.${user}) projectUsers;
    merged = mergeUserCerts certs;
  in
    merged
    // {
      inherit certs certsByName projectUsers;
      userCertificates = certFilesByName root certsByName;
    };
in {
  inherit certFiles certFilesByName certFilesForUsers mergeUserCerts mkUserCertsForProjects mkUserCertWithKeys projectsForUser usersFromProjects;
}

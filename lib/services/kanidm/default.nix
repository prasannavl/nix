{
  lib,
  pkgs,
}: let
  normalizeList = value:
    if value == null
    then []
    else if builtins.isList value
    then value
    else [value];

  normalizeAccountId = value:
    if builtins.isString value
    then lib.head (lib.splitString "@" value)
    else value;

  normalizePerson = accountId: person: {
    accountId = accountId;
    displayName = person.displayName or accountId;
    legalName = person.legalName or null;
    mail = normalizeList (person.mail or []);
    sshPublicKeys = person.sshPublicKeys or {};
    posix =
      {
        enable = false;
      }
      // (person.posix or {});
  };

  normalizeServiceAccount = accountId: serviceAccount: {
    accountId = accountId;
    displayName = serviceAccount.displayName or accountId;
    entryManagedBy = serviceAccount.entryManagedBy or "idm_admin";
    mail = normalizeList (serviceAccount.mail or []);
    sshPublicKeys = serviceAccount.sshPublicKeys or {};
  };

  normalizeGroup = name: group: {
    name = name;
    description = group.description or null;
    mail =
      if group ? mail
      then normalizeList group.mail
      else null;
    members =
      if group.members or null == null
      then null
      else map normalizeAccountId (normalizeList group.members);
  };

  normalizeGroupMembers = name: members: {
    name = name;
    members = map normalizeAccountId (normalizeList members);
  };

  normalizeAbsentGroup = name: {
    name = normalizeAccountId name;
  };

  materializeOauthIcon = name: icon: let
    iconPath = toString icon;
    iconFileName = builtins.baseNameOf iconPath;
    iconStorePath =
      if builtins.pathExists icon
      then
        pkgs.runCommand "kanidm-oauth-${lib.strings.sanitizeDerivationName name}-icon-${lib.strings.sanitizeDerivationName iconFileName}" {
          src = icon;
          preferLocalBuild = true;
          allowSubstitutes = false;
        } ''
          install -Dm444 "$src" "$out"/${lib.escapeShellArg iconFileName}
        ''
      else throw "kanidm oauth app '${name}' icon path does not exist: ${iconPath}";
  in "${iconStorePath}/${iconFileName}";

  normalizeOauthApp = name: client: {
    name = name;
    displayName = client.displayName or name;
    type = client.type or "confidential";
    origin = client.origin;
    landingUrl = client.landingUrl or client.origin;
    iconPath =
      if client ? icon
      then materializeOauthIcon name client.icon
      else null;
    ui = client.ui or {};
    redirectUrls = client.redirectUrls or [];
    scopeMaps = client.scopeMaps or {};
    pkce = client.pkce or true;
  };
  normalizeOauthAppEntry = entry:
    if entry ? name && entry ? value
    then normalizeOauthApp entry.name entry.value
    else normalizeOauthApp entry.name (builtins.removeAttrs entry ["name"]);
  normalizeOauthApps = oauthApps:
    if builtins.isList oauthApps
    then map normalizeOauthAppEntry oauthApps
    else lib.mapAttrsToList normalizeOauthApp oauthApps;

  normalizeScimApp = name: application: {
    name = name;
    displayName = application.displayName or name;
    linkedGroup = application.linkedGroup;
  };

  normalizeState = state: {
    domain = state.domain or {};
    pruneGroups = state.pruneGroups or false;
    pruneGroupMembers = state.pruneGroupMembers or false;
    pruneOauthApps = state.pruneOauthApps or false;
    pruneOauthRedirectUrls = state.pruneOauthRedirectUrls or false;
    pruneOauthScopeMaps = state.pruneOauthScopeMaps or false;
    pruneScimApps = state.pruneScimApps or false;
    pruneServiceAccounts = state.pruneServiceAccounts or false;
    pruneSshPublicKeys = state.pruneSshPublicKeys or false;
    pruneUsers = state.pruneUsers or false;
    users = lib.mapAttrsToList normalizePerson (state.users or {});
    serviceAccounts = lib.mapAttrsToList normalizeServiceAccount (state.serviceAccounts or {});
    groups = lib.mapAttrsToList normalizeGroup (state.groups or {});
    absentGroups = map normalizeAbsentGroup (normalizeList (state.absentGroups or []));
    groupMembers = lib.mapAttrsToList normalizeGroupMembers (state.groupMembers or {});
    scimApps = lib.mapAttrsToList normalizeScimApp (state.scimApps or {});
    oauthApps = normalizeOauthApps (state.oauthApps or {});
  };
in {
  mkServerConfig = {
    bindAddress ? "0.0.0.0:8443",
    dbPath ? "/data/kanidm.db",
    domain,
    origin ? "https://${domain}",
    tlsChain ? "/data/tls/chain.pem",
    tlsKey ? "/data/tls/key.pem",
    trustedForwardedFor ? [
      "127.0.0.1"
      "127.0.0.0/8"
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
    ],
    backupPath ? "/data/backups",
    backupSchedule ? "00 22 * * *",
    backupVersions ? 14,
    ldapBindAddress ? null,
  }: ''
    version = "2"
    bindaddress = "${bindAddress}"
    ${lib.optionalString (ldapBindAddress != null) ''
      ldapbindaddress = "${ldapBindAddress}"
    ''}
    db_path = "${dbPath}"
    tls_chain = "${tlsChain}"
    tls_key = "${tlsKey}"
    domain = "${domain}"
    origin = "${origin}"

    [http_client_address_info]
    x-forward-for = [
    ${lib.concatMapStringsSep "\n" (cidr: "  \"${cidr}\",") trustedForwardedFor}
    ]

    [online_backup]
    path = "${backupPath}"
    schedule = "${backupSchedule}"
    versions = ${toString backupVersions}
  '';

  mkApplyScript = {
    name ? "kanidm-apply",
    url,
    adminName ? "idm_admin",
    systemAdminName ? "admin",
    state ? {},
    kanidmPackage ? pkgs.kanidm_1_9,
  }: let
    metadata = pkgs.writeText "${name}.json" (builtins.toJSON {
      name = name;
      url = url;
      adminName = adminName;
      systemAdminName = systemAdminName;
      state = normalizeState state;
    });
  in
    pkgs.writeShellApplication {
      name = name;
      excludeShellChecks = ["SC1091"];
      runtimeInputs = [
        kanidmPackage
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.jq
        pkgs.systemd
      ];
      runtimeEnv.KANIDM_DECLARATIVE_METADATA = metadata;
      text = ''
        source ${./helper.sh}
        main "$@"
      '';
    };

  mkPasswordAutoApplyScript = {
    name ? "kanidm-auto-apply-idm",
    applyScript,
    applyCommandName,
    url,
    domain ? null,
    adminName ? "idm_admin",
    passwordFile,
    command ? "apply-idm",
    acceptInvalidCerts ? false,
    waitSeconds ? 60,
  }:
    pkgs.writeShellApplication {
      name = name;
      runtimeEnv =
        {
          KANIDM_URL = url;
          KANIDM_NAME = adminName;
          KANIDM_AUTO_APPLY_PASSWORD_FILE = passwordFile;
          KANIDM_AUTO_APPLY_COMMAND = command;
          KANIDM_AUTO_APPLY_WAIT_SECONDS = toString waitSeconds;
        }
        // lib.optionalAttrs (domain != null) {
          KANIDM_DOMAIN = domain;
        }
        // lib.optionalAttrs acceptInvalidCerts {
          KANIDM_ACCEPT_INVALID_CERTS = "true";
        };
      text = ''
        exec ${lib.escapeShellArg "${applyScript}/bin/${applyCommandName}"} auto-apply-idm
      '';
    };
}

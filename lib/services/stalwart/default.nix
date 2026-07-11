{pkgs}: let
  lib = pkgs.lib;
  mailDirectoryLib = import ../mail-directory {inherit lib;};
  mkUserdataProvisioning = {
    domainId,
    domainName,
    groupDefinitions ? {},
    roleGroups ? {
      user = ["users"];
      admin = ["admins"];
    },
    groupSets,
    userSets,
    users,
  }: let
    mailDirectory = mailDirectoryLib.mkUserdataDirectory {
      inherit
        domainName
        groupDefinitions
        groupSets
        users
        ;
    };

    mailingListForGroup = group: {
      name = group.listName;
      inherit domainId;
      recipients = group.recipients;
      description = "Userdata-managed ${group.name} mailing list.";
      aliases =
        map (localPart: {
          name = localPart;
          inherit domainId;
          enabled = true;
        })
        group.aliasLocalParts;
    };

    sharedGroupForGroup = group: {
      name = group.sharedName;
      inherit domainId;
      description =
        if group.sharedDescription != null
        then group.sharedDescription
        else "Userdata-managed ${group.name} shared mailbox.";
      aliases =
        map (localPart: {
          name = localPart;
          inherit domainId;
          enabled = true;
        })
        group.sharedAliasLocalParts;
    };

    mailingLists = map mailingListForGroup mailDirectory.mailingListGroups;
    sharedGroups = map sharedGroupForGroup mailDirectory.sharedGroups;

    userRoles =
      map (userId: let
        details = users.${userId};
        name =
          if details.email != null
          then lib.removeSuffix "@${domainName}" details.email
          else details.username;
      in {
        inherit domainId name;
        description = details.name or details.username;
        role =
          if groupSets.hasAnyGroup roleGroups.admin details
          then "Admin"
          else "User";
      })
      (
        builtins.attrNames (
          lib.filterAttrs (_: details: details.mailEnabled && groupSets.hasAnyGroup roleGroups.user details) userSets.active
        )
      );
  in {
    inherit
      mailDirectory
      mailingLists
      sharedGroups
      userRoles
      ;
    inherit (mailDirectory) internalMailingListAddresses;
  };
  tests = import ./tests {inherit pkgs mkUserdataProvisioning;};
in {
  inherit mkUserdataProvisioning;

  mkDataStoreConfig = {
    type ? "RocksDb",
    path ? "/var/lib/stalwart",
  }:
    builtins.toJSON {
      "@type" = type;
      path = path;
    };

  mkApplyScript = {
    name ? "stalwart-apply",
    configHostPath,
    containerName ? "stalwart_stalwart_1",
    dataDir,
    image,
    imageTar ? null,
    kanidmLdapTokenHostPath ? "/run/agenix/stalwart-kanidm-ldap-token",
    planContainerPath ? "/etc/stalwart/provisioning/plan.json",
    planHostPath,
    userRolesHostPath ? "",
    mailingListsHostPath ? "",
    sharedGroupsHostPath ? "",
    recoveryContainerName ? "stalwart-recovery",
    recoveryWaitSeconds ? 120,
    recoveryUrl ? "http://127.0.0.1:8080",
    serviceName ? "stalwart.service",
    url ? "http://127.0.0.1:8080",
    credentialsFile ? "/run/agenix/stalwart-recovery-admin",
    domainId ? "",
    domainName ? "",
    extraRecoveryMounts ? [],
    planStringFileSubstitutions ? {},
    defaultCertificate ? null,
    pruneCertificates ? false,
    pruneGroups ? false,
    pruneMailingLists ? false,
    pruneMtaRoutes ? false,
    pruneSieveSystemScripts ? false,
    pruneUsers ? false,
    runtime ? "podman",
  }:
    (pkgs.writeShellApplication {
      name = name;
      excludeShellChecks = [
        "SC1091"
        "SC2089"
        "SC2090"
      ];
      runtimeInputs =
        [
          pkgs.coreutils
          pkgs.jq
          pkgs.util-linux
        ]
        ++ lib.optional (runtime == "podman") pkgs.podman
        ++ lib.optional (runtime == "systemd") pkgs.systemd;
      runtimeEnv =
        {
          STALWART_CLI_BIN = "${pkgs.stalwart-cli}/bin/stalwart-cli";
          STALWART_CONFIG_HOST_PATH = configHostPath;
          STALWART_CONTAINER = containerName;
          STALWART_CREDENTIALS_FILE = credentialsFile;
          STALWART_DATA_DIR = dataDir;
          STALWART_DEFAULT_CERTIFICATE = builtins.toJSON defaultCertificate;
          STALWART_DOMAIN_ID = domainId;
          STALWART_DOMAIN_NAME = domainName;
          STALWART_EXTRA_RECOVERY_MOUNTS = builtins.concatStringsSep "\n" (map (mount: "${mount.hostPath}:${mount.containerPath}") extraRecoveryMounts);
          STALWART_IMAGE = image;
          STALWART_KANIDM_LDAP_TOKEN_HOST_PATH = kanidmLdapTokenHostPath;
          STALWART_PLAN_CONTAINER_PATH = planContainerPath;
          STALWART_PLAN_HOST_PATH = planHostPath;
          STALWART_PLAN_STRING_FILE_SUBSTITUTIONS =
            builtins.concatStringsSep "\n"
            (lib.mapAttrsToList (placeholder: hostPath: "${placeholder}\t${hostPath}") planStringFileSubstitutions);
          STALWART_PRUNE_CERTIFICATES =
            if pruneCertificates
            then "true"
            else "false";
          STALWART_PRUNE_GROUPS =
            if pruneGroups
            then "true"
            else "false";
          STALWART_PRUNE_MAILING_LISTS =
            if pruneMailingLists
            then "true"
            else "false";
          STALWART_PRUNE_MTA_ROUTES =
            if pruneMtaRoutes
            then "true"
            else "false";
          STALWART_PRUNE_SIEVE_SYSTEM_SCRIPTS =
            if pruneSieveSystemScripts
            then "true"
            else "false";
          STALWART_PRUNE_USERS =
            if pruneUsers
            then "true"
            else "false";
          STALWART_RECOVERY_CONTAINER = recoveryContainerName;
          STALWART_RECOVERY_WAIT_SECONDS = toString recoveryWaitSeconds;
          STALWART_RECOVERY_URL = recoveryUrl;
          STALWART_RUNTIME = runtime;
          STALWART_SERVICE_NAME = serviceName;
          STALWART_SHARED_GROUPS_HOST_PATH = sharedGroupsHostPath;
          STALWART_URL = url;
          STALWART_USER_ROLES_HOST_PATH = userRolesHostPath;
          STALWART_MAILING_LISTS_HOST_PATH = mailingListsHostPath;
        }
        // lib.optionalAttrs (imageTar != null) {
          STALWART_IMAGE_TAR = "${imageTar}";
        };
      text = ''
        source ${./helper.sh}
        main "$@"
      '';
    })
    .overrideAttrs (old: let
      oldPassthru = old.passthru or {};
    in {
      passthru =
        oldPassthru
        // {
          tests = (oldPassthru.tests or {}) // tests;
        };
    });
}

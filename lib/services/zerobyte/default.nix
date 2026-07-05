{pkgs}: {
  mkApplyScript = {
    name ? "zerobyte-apply",
    autoLinkMatchingEmails ? true,
    clientId,
    clientSecretFile,
    containerName ? "zerobyte_zerobyte_1",
    databasePath ? "/var/lib/zerobyte/data/zerobyte.db",
    domain,
    discoveryEndpoint,
    issuerUrl,
    organizationId ? "",
    organizationSlug ? "",
    providerId ? "kanidm",
    waitSeconds ? 120,
  }:
    pkgs.writeShellApplication {
      name = name;
      excludeShellChecks = ["SC1091"];
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
        pkgs.podman
      ];
      runtimeEnv = {
        ZEROBYTE_AUTO_LINK_MATCHING_EMAILS =
          if autoLinkMatchingEmails
          then "true"
          else "false";
        ZEROBYTE_CLIENT_ID = clientId;
        ZEROBYTE_CLIENT_SECRET_FILE = clientSecretFile;
        ZEROBYTE_CONTAINER = containerName;
        ZEROBYTE_DATABASE_PATH = databasePath;
        ZEROBYTE_DOMAIN = domain;
        ZEROBYTE_DISCOVERY_ENDPOINT = discoveryEndpoint;
        ZEROBYTE_ISSUER_URL = issuerUrl;
        ZEROBYTE_ORGANIZATION_ID = organizationId;
        ZEROBYTE_ORGANIZATION_SLUG = organizationSlug;
        ZEROBYTE_PROVIDER_ID = providerId;
        ZEROBYTE_WAIT_SECONDS = toString waitSeconds;
      };
      text = ''
        source ${./helper.sh}
        main "$@"
      '';
    };
}

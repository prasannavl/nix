{pkgs}: {
  mkApplyScript = {
    name ? "forgejo-apply",
    adminGroup ? "",
    authName ? "kanidm",
    clientId,
    clientSecretFile,
    configPath ? "/var/lib/gitea/custom/conf/app.ini",
    containerName ? "forgejo_forgejo_1",
    groupClaimName ? "groups",
    issuerUrl,
    workPath ? "/var/lib/gitea",
    waitSeconds ? 120,
  }:
    pkgs.writeShellApplication {
      name = name;
      excludeShellChecks = ["SC1091"];
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gawk
        pkgs.gnugrep
        pkgs.podman
      ];
      runtimeEnv = {
        FORGEJO_ADMIN_GROUP = adminGroup;
        FORGEJO_AUTH_NAME = authName;
        FORGEJO_CLIENT_ID = clientId;
        FORGEJO_CLIENT_SECRET_FILE = clientSecretFile;
        FORGEJO_CONFIG_PATH = configPath;
        FORGEJO_CONTAINER = containerName;
        FORGEJO_GROUP_CLAIM_NAME = groupClaimName;
        FORGEJO_ISSUER_URL = issuerUrl;
        FORGEJO_WAIT_SECONDS = toString waitSeconds;
        FORGEJO_WORK_PATH = workPath;
      };
      text = ''
        source ${./helper.sh}
        main "$@"
      '';
    };
}

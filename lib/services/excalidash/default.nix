{pkgs}: {
  mkHelperScript = {
    name ? "excalidash-helper",
    backendDataDir,
    backendImage,
    databaseProvider ? "sqlite",
    databaseUrl ? "file:/app/prisma/dev.db",
    dataDir,
    envFile,
    migrationLockFile,
  }:
    pkgs.writeShellApplication {
      name = name;
      excludeShellChecks = ["SC1091"];
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.openssl
        pkgs.podman
        pkgs.util-linux
      ];
      runtimeEnv = {
        EXCALIDASH_BACKEND_DATA_DIR = backendDataDir;
        EXCALIDASH_BACKEND_IMAGE = backendImage;
        EXCALIDASH_DATABASE_PROVIDER = databaseProvider;
        EXCALIDASH_DATABASE_URL = databaseUrl;
        EXCALIDASH_DATA_DIR = dataDir;
        EXCALIDASH_ENV_FILE = envFile;
        EXCALIDASH_HELPER_PATH = "${./helper.sh}";
        EXCALIDASH_MIGRATION_LOCK_FILE = migrationLockFile;
      };
      text = ''
        export EXCALIDASH_HELPER_NO_MAIN=1
        source ${./helper.sh}
        main "$@"
      '';
    };
}

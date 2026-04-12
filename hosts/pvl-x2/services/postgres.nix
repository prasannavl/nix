{pkgs, ...}: let
  postgresImage = "docker.io/timescale/timescaledb-ha:pg18";
  postgresDataDir = "/var/lib/pvl/postgres";
  postgresUid = "1000";
  postgresGid = "1000";
in {
  systemd.tmpfiles.rules = [
    "d ${postgresDataDir} 0750 pvl pvl -"
  ];

  services.podmanCompose.pvl.instances.postgres = rec {
    exposedPorts.main = {
      port = 5432;
    };

    source = ''
      services:
        postgres:
          image: ${postgresImage}
          ports:
            - "127.0.0.1:${toString exposedPorts.main.port}:5432"
          environment:
            POSTGRES_USER: postgres
            POSTGRES_DB: pvl
            POSTGRES_HOST_AUTH_METHOD: trust
            TIMESCALEDB_TELEMETRY: "off"
          volumes:
            - ${postgresDataDir}:/home/postgres/pgdata/data
            - ./initdb/10-extensions.sql:/docker-entrypoint-initdb.d/10-extensions.sql:ro
    '';
    files."initdb/10-extensions.sql" = ''
      CREATE EXTENSION IF NOT EXISTS timescaledb;
      CREATE EXTENSION IF NOT EXISTS postgis;
      CREATE EXTENSION IF NOT EXISTS vector;
      CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
    '';
    serviceOverrides.preStart = ''
      ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/install -d -m 0700 -o ${postgresUid} -g ${postgresGid} ${postgresDataDir}
      ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/chown -R ${postgresUid}:${postgresGid} ${postgresDataDir}
      ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/chmod 0700 ${postgresDataDir}
    '';
  };
}

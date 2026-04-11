{...}: {
  systemd.tmpfiles.rules = [
    "d /var/lib/pvl/postgres 0750 pvl pvl -"
  ];

  services.podmanCompose.pvl.instances.postgres = rec {
    exposedPorts.main = {
      port = 5432;
    };

    source = ''
      services:
        postgres:
          image: docker.io/timescale/timescaledb-ha:pg18
          restart: unless-stopped
          ports:
            - "127.0.0.1:${toString exposedPorts.main.port}:5432"
          environment:
            POSTGRES_USER: postgres
            POSTGRES_DB: pvl
            POSTGRES_HOST_AUTH_METHOD: trust
            TIMESCALEDB_TELEMETRY: "off"
          volumes:
            - /var/lib/pvl/postgres:/home/postgres/pgdata/data:Z,U
            - ./initdb/10-extensions.sql:/docker-entrypoint-initdb.d/10-extensions.sql:ro,Z
    '';
    files."initdb/10-extensions.sql" = ''
      CREATE EXTENSION IF NOT EXISTS timescaledb;
      CREATE EXTENSION IF NOT EXISTS postgis;
      CREATE EXTENSION IF NOT EXISTS vector;
      CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
    '';
  };
}

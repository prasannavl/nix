{lib, ...}: let
  # Disabled stack. Keep the compose definition inline until Zulip is wired
  # back into the host again.
  composeSource = ''
    services:
      database:
        image: "zulip/zulip-postgresql:14"
        environment:
          POSTGRES_DB: "zulip"
          POSTGRES_USER: "zulip"
          POSTGRES_PASSWORD: "REPLACE_WITH_SECURE_POSTGRES_PASSWORD"
        volumes:
          - "postgresql-14:/var/lib/postgresql/data:rw"
      memcached:
        image: "memcached:alpine"
        command:
          - "sh"
          - "-euc"
          - |
            echo 'mech_list: plain' > "$$SASL_CONF_PATH"
            echo "zulip@$$HOSTNAME:$$MEMCACHED_PASSWORD" > "$$MEMCACHED_SASL_PWDB"
            echo "zulip@localhost:$$MEMCACHED_PASSWORD" >> "$$MEMCACHED_SASL_PWDB"
            exec memcached -S
        environment:
          SASL_CONF_PATH: "/home/memcache/memcached.conf"
          MEMCACHED_SASL_PWDB: "/home/memcache/memcached-sasl-db"
          MEMCACHED_PASSWORD: "REPLACE_WITH_SECURE_MEMCACHED_PASSWORD"
      rabbitmq:
        image: "rabbitmq:4.0.7"
        environment:
          RABBITMQ_DEFAULT_USER: "zulip"
          RABBITMQ_DEFAULT_PASS: "REPLACE_WITH_SECURE_RABBITMQ_PASSWORD"
        volumes:
          - "rabbitmq:/var/lib/rabbitmq:rw"
      redis:
        image: "redis:alpine"
        command:
          - "sh"
          - "-euc"
          - |
            echo "requirepass '$$REDIS_PASSWORD'" > /etc/redis.conf
            exec redis-server /etc/redis.conf
        environment:
          REDIS_PASSWORD: "REPLACE_WITH_SECURE_REDIS_PASSWORD"
        volumes:
          - "redis:/data:rw"
      zulip:
        image: "zulip/docker-zulip:11.2-0"
        build:
          context: .
          args:
            ZULIP_GIT_URL: https://github.com/zulip/zulip.git
            ZULIP_GIT_REF: "11.2"
        ports:
          - "25:25"
          - "80:80"
          - "443:443"
        environment:
          DB_HOST: "database"
          DB_HOST_PORT: "5432"
          DB_USER: "zulip"
          SSL_CERTIFICATE_GENERATION: "self-signed"
          SETTING_MEMCACHED_LOCATION: "memcached:11211"
          SETTING_RABBITMQ_HOST: "rabbitmq"
          SETTING_REDIS_HOST: "redis"
          SECRETS_email_password: "123456789"
          SECRETS_rabbitmq_password: "REPLACE_WITH_SECURE_RABBITMQ_PASSWORD"
          SECRETS_postgres_password: "REPLACE_WITH_SECURE_POSTGRES_PASSWORD"
          SECRETS_memcached_password: "REPLACE_WITH_SECURE_MEMCACHED_PASSWORD"
          SECRETS_redis_password: "REPLACE_WITH_SECURE_REDIS_PASSWORD"
          SECRETS_secret_key: "REPLACE_WITH_SECURE_SECRET_KEY"
          SETTING_EXTERNAL_HOST: "localhost.localdomain"
          SETTING_ZULIP_ADMINISTRATOR: "admin@example.com"
          SETTING_EMAIL_HOST: ""
          SETTING_EMAIL_HOST_USER: "noreply@example.com"
          SETTING_EMAIL_PORT: "587"
          SETTING_EMAIL_USE_SSL: "False"
          SETTING_EMAIL_USE_TLS: "True"
          ZULIP_AUTH_BACKENDS: "EmailAuthBackend"
        volumes:
          - "zulip:/data:rw"
        ulimits:
          nofile:
            soft: 1000000
            hard: 1048576
    volumes:
      zulip:
      postgresql-14:
      rabbitmq:
      redis:
  '';
in {
  config = lib.mkIf false {
    services.podmanCompose.pvl.instances.zulip.source = composeSource;
  };
}

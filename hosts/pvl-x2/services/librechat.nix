{
  config,
  pkgs,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  ai = config.services.ai;
  librechatDataDir = "/var/lib/pvl/librechat";
  librechatEnvFile = "${librechatDataDir}/librechat.env";
  librechatUrl = registry.urlPublicFor "librechat";
  containerHost = "host.containers.internal";
  # Ollama OpenAI-compatible endpoint as seen from inside the container. The
  # ROCm deployment is the auto-started primary on pvl-x2.
  ollamaPort = ai.backends.ollama.portsByName."ollama-rocm";
  ollamaBaseUrl = "http://${containerHost}:${toString ollamaPort}";
  # llama.cpp router deployments expose an OpenAI-compatible /v1.
  llamaPortsByName = ai.backends.llamaRouter.runtimesInfo.default.portsByName or {};
  llamaRocmPort = llamaPortsByName."llama-rocm" or null;
  llamaCpuPort = llamaPortsByName."llama-cpu" or null;
  ollamaNoProxy = "localhost,127.0.0.1,::1,mongodb,meilisearch,${containerHost}";
  embeddingKey = ai.roles.embedding;
  # Only models the Ollama endpoint can actually serve: entries with an
  # `ollama` tag, excluding the embedding model.
  chatModelIds =
    builtins.map
    (key: ai.catalog.${key}.id)
    (builtins.filter (
        key:
          key
          != embeddingKey
          && (ai.catalog.${key} ? ollama)
      )
      ai.resolvedModels);
  containerOwner = {
    user = 1000;
    group = 1000;
    scope = "container";
  };
  rootOwner = {
    user = 0;
    group = 0;
    scope = "container";
  };
in {
  # Local-auth LibreChat (no IdM on pvl) backed by MongoDB and Meilisearch.
  # The custom endpoint points at the host Ollama over host.containers.internal;
  # no tunnel hostname is declared yet, so this is LAN/tailnet-only via nginx.
  services.podman-compose.pvl.instances.librechat = rec {
    exposedPorts.http = {
      port = registry.portFor "librechat" "http";
      openFirewall = true;
      nginxHostNames = registry.domains.librechat;
    };

    source = ''
      services:
        api:
          image: registry.librechat.ai/danny-avila/librechat-dev@sha256:bab0fbb54a74981b1eb67057083da493fe0f87e54525c6d5cf43e9df9009bf54
          restart: unless-stopped
          user: "1000:1000"
          depends_on:
            - mongodb
            - meilisearch
          env_file:
            - ${librechatEnvFile}
          ports:
            - "${toString exposedPorts.http.port}:3080"
          environment:
            HOST: "0.0.0.0"
            PORT: "3080"
            CONFIG_PATH: /app/librechat.yaml
            DOMAIN_CLIENT: "${librechatUrl}"
            DOMAIN_SERVER: "${librechatUrl}"
            MONGO_URI: mongodb://mongodb:27017/LibreChat
            MEILI_HOST: http://meilisearch:7700
            NO_PROXY: "${ollamaNoProxy}"
            TRUST_PROXY: "1"
            ENDPOINTS: custom
            ALLOW_REGISTRATION: "true"
            ALLOW_EMAIL_LOGIN: "true"
            ALLOW_SOCIAL_LOGIN: "false"
            ALLOW_SOCIAL_REGISTRATION: "false"
            ALLOW_PASSWORD_RESET: "false"
            ALLOW_UNVERIFIED_EMAIL_LOGIN: "true"
            SEARCH: "true"
            MEILI_NO_ANALYTICS: "true"
            OPENAI_MODERATION: "false"
            BAN_VIOLATIONS: "true"
            CONSOLE_JSON: "true"
            DEBUG_LOGGING: "false"
            DEBUG_CONSOLE: "false"
            LOG_TO_FILE: "true"
          volumes:
            - ./librechat.yaml:/app/librechat.yaml:ro
            - ${librechatDataDir}/images:/app/client/public/images
            - ${librechatDataDir}/uploads:/app/uploads
            - ${librechatDataDir}/logs:/app/logs
            - ${librechatDataDir}/skill:/app/skill

        mongodb:
          image: docker.io/library/mongo:8.3.11
          restart: unless-stopped
          user: "1000:1000"
          command: mongod --noauth
          volumes:
            - ${librechatDataDir}/mongodb:/data/db

        meilisearch:
          # Startup upgrades mutate persisted data; back up before deployment.
          image: docker.io/getmeili/meilisearch:v1.54.0
          restart: unless-stopped
          user: "1000:1000"
          env_file:
            - ${librechatEnvFile}
          environment:
            MEILI_NO_ANALYTICS: "true"
            MEILI_UPGRADE_DB: "true"
          volumes:
            - ${librechatDataDir}/meilisearch:/meili_data
    '';

    dirs =
      builtins.listToAttrs (
        map
        (path: {
          name = path;
          value =
            {
              mode = "0750";
              once = true;
            }
            // containerOwner;
        })
        [
          "${librechatDataDir}/images"
          "${librechatDataDir}/uploads"
          "${librechatDataDir}/logs"
          "${librechatDataDir}/skill"
          "${librechatDataDir}/mongodb"
          "${librechatDataDir}/meilisearch"
        ]
      )
      // {
        "${librechatDataDir}" =
          {
            mode = "0750";
            once = false;
          }
          // rootOwner;
      };

    files."librechat.yaml" =
      {
        mode = "0640";
        text = ''
          version: 1.2.8
          endpoints:
            custom:
              - name: "Pvl Ollama"
                apiKey: "ollama"
                baseURL: "${ollamaBaseUrl}/v1"
                models:
                  default: ${builtins.toJSON chatModelIds}
                  fetch: true
                titleConvo: true
                titleModel: "current_model"
                summarize: false
                summaryModel: "current_model"
                modelDisplayLabel: "Pvl Ollama"
              - name: "Pvl llama.cpp ROCm"
                apiKey: "ollama"
                baseURL: "http://${containerHost}:${toString llamaRocmPort}/v1"
                models:
                  default: ${builtins.toJSON chatModelIds}
                  fetch: true
                titleConvo: true
                titleModel: "current_model"
                summarize: false
                summaryModel: "current_model"
                modelDisplayLabel: "Pvl llama.cpp ROCm"
              - name: "Pvl llama.cpp CPU"
                apiKey: "ollama"
                baseURL: "http://${containerHost}:${toString llamaCpuPort}/v1"
                models:
                  default: ${builtins.toJSON chatModelIds}
                  fetch: true
                titleConvo: true
                titleModel: "current_model"
                summarize: false
                summaryModel: "current_model"
                modelDisplayLabel: "Pvl llama.cpp CPU"
        '';
      }
      // containerOwner;

    preStart = [
      ''
        ensure_secret() {
          local name="$1"
          local bytes="$2"
          local env_file="${librechatEnvFile}"
          local current
          local tmp
          local value

          current="$(
            awk -F= -v name="$name" \
              '$1 == name { print substr($0, length($1) + 2); exit }' \
              "$env_file" 2>/dev/null
          )"
          if [ -n "$current" ]; then
            return
          fi

          value="$(${pkgs.openssl}/bin/openssl rand -hex "$bytes")"
          tmp="$(mktemp "''${env_file}.tmp.XXXXXX")"
          awk -F= -v name="$name" -v value="$value" '
            BEGIN { written = 0 }
            $1 == name {
              if (!written) {
                print name "=" value
                written = 1
              }
              next
            }
            { print }
            END {
              if (!written) {
                print name "=" value
              }
            }
          ' "$env_file" > "$tmp"
          cat "$tmp" > "$env_file"
          rm -f "$tmp"
        }

        umask 077
        touch ${librechatEnvFile}
        chmod 0600 ${librechatEnvFile}
        ensure_secret MEILI_MASTER_KEY 32
        ensure_secret CREDS_KEY 32
        ensure_secret CREDS_IV 16
        ensure_secret JWT_SECRET 32
        ensure_secret JWT_REFRESH_SECRET 32
      ''
    ];
  };
}

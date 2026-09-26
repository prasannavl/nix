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
  # Every Ollama/llama.cpp endpoint for this host, from the shared consumer
  # projection: `default` is the primary Ollama, `openaiDefault` its `/v1`.
  consumers = ai.consumersFor containerHost;
  deviceLabels = {
    rocm = "ROCm";
    nvidia = "NVIDIA";
    cpu = "CPU";
  };
  deviceLabel = device: deviceLabels.${device} or "llama.cpp";
  runtimeLabels = {
    default = "llama.cpp";
    prism = "Prism";
  };
  endpointLabel = endpoint: let
    runtime = endpoint.runtime or "default";
  in "${runtimeLabels.${runtime} or runtime} ${deviceLabel endpoint.device}";
  # One custom-endpoint shape, reused for the primary Ollama endpoint and each
  # configured llama.cpp runtime/device pair; `librechatConfig` is rendered to
  # YAML.
  customEndpoint = name: baseURL: modelIds: {
    inherit name baseURL;
    apiKey = "ollama";
    models = {
      default = modelIds;
      fetch = true;
    };
    titleConvo = true;
    titleModel = "current_model";
    summarize = false;
    summaryModel = "current_model";
    modelDisplayLabel = name;
  };
  embeddingModelId = ai.catalog.${ai.roles.embedding}.id;
  chatModelIdsFor = endpoint:
    builtins.filter (modelId: modelId != embeddingModelId) endpoint.modelIds;
  ollamaEndpoint = builtins.head consumers.ollama.endpoints;
  librechatConfig = {
    version = "1.2.8";
    endpoints.custom =
      [(customEndpoint "Pvl Ollama" "${ollamaEndpoint.url}/v1" (chatModelIdsFor ollamaEndpoint))]
      ++ builtins.map
      (endpoint:
        customEndpoint
        "Pvl ${endpointLabel endpoint}"
        "${endpoint.url}/v1"
        (chatModelIdsFor endpoint))
      consumers.llama.endpoints;
  };
  ollamaNoProxy = "localhost,127.0.0.1,::1,mongodb,meilisearch,${containerHost}";
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
        source = (pkgs.formats.yaml {}).generate "librechat.yaml" librechatConfig;
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

{
  config,
  pkgs,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  ai = config.services.ai;
  opendesignDataDir = "/var/lib/pvl/opendesign";
  opendesignUrl = registry.urlPublicFor "opendesign";
  consumers = ai.consumersFor "host.containers.internal";
  ollamaUpstreamUrl = consumers.ollama.default;
  ollamaLoopbackUrl = "http://127.0.0.1:11434";
  ollamaNoProxy = "localhost,127.0.0.1,::1,host.containers.internal";
  modelKey =
    if ai.roles.main != null
    then ai.roles.main
    else "qwen35-4b";
  modelId = ai.catalog.${modelKey}.id;
  opendesignPackage = pkgs.opendesign.override {
    managedByokProvider = {
      id = "pvl-ai";
      title = "Pvl AI";
      label = "Pvl AI (Ollama)";
      protocol = "ollama";
      baseUrl = ollamaLoopbackUrl;
      model = modelId;
      apiKey = "ollama";
      requiresApiKey = false;
    };
  };
in {
  # OpenDesign is LAN/tailnet-only for now (nginx vhost, no tunnel hostname).
  # The in-container loopback proxy bridges the app's fixed 127.0.0.1:11434
  # expectation to the host Ollama over host.containers.internal.
  services.podman-compose.pvl.instances.opendesign = rec {
    exposedPorts.http = {
      port = registry.portFor "opendesign" "http";
      openFirewall = true;
      nginxHostNames = registry.domains.opendesign;
    };

    source = ''
      services:
        opendesign:
          image: nix-store:${opendesignPackage}
          restart: unless-stopped
          read_only: true
          tmpfs:
            - /tmp:rw,mode=1777
          security_opt:
            - no-new-privileges:true
          mem_limit: 384m
          pids_limit: 256
          ports:
            - "${toString exposedPorts.http.port}:7456"
          environment:
            NODE_ENV: production
            NODE_OPTIONS: "--max-old-space-size=192"
            OD_BIND_HOST: "0.0.0.0"
            OD_ALLOWED_ORIGINS: "${opendesignUrl}"
            OD_PORT: "7456"
            OD_WEB_PORT: "7456"
            OD_DISABLE_API_AUTH: "1"
            PVL_OLLAMA_BASE_URL: "${ollamaUpstreamUrl}"
            OLLAMA_HOST: "${ollamaLoopbackUrl}"
            OPENAI_BASE_URL: "${ollamaLoopbackUrl}/v1"
            OPENAI_API_KEY: "ollama"
            CODEX_API_KEY: "ollama"
            NO_PROXY: "${ollamaNoProxy}"
          command:
            - /app/pvl-run-opendesign.sh
          volumes:
            - ${opendesignDataDir}:/app/.od
            - ./run-opendesign.sh:/app/pvl-run-opendesign.sh:ro
            - ./ollama-loopback-proxy.cjs:/app/pvl-ollama-loopback-proxy.cjs:ro
          healthcheck:
            test:
              - CMD
              - node
              - -e
              - "fetch('http://127.0.0.1:7456/api/health').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
            interval: 30s
            timeout: 5s
            retries: 3
            start_period: 20s
    '';

    dirs.${opendesignDataDir} = {
      mode = "0750";
      once = false;
      user = 1001;
      group = 1001;
      scope = "container";
    };

    files."ollama-loopback-proxy.cjs" = {
      mode = "0444";
      text = ''
        const http = require("node:http");
        const https = require("node:https");

        const targetBase = new URL(process.env.PVL_OLLAMA_BASE_URL);
        const listenHost = "127.0.0.1";
        const listenPort = 11434;

        const server = http.createServer((clientReq, clientRes) => {
          const targetUrl = new URL(clientReq.url || "/", targetBase);
          const clientHeaders = { ...clientReq.headers, host: targetUrl.host };
          delete clientHeaders.connection;
          delete clientHeaders["proxy-connection"];
          delete clientHeaders["transfer-encoding"];

          const upstreamReq = (targetUrl.protocol === "https:" ? https : http).request(
            targetUrl,
            {
              method: clientReq.method,
              headers: clientHeaders,
            },
            (upstreamRes) => {
              clientRes.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
              upstreamRes.pipe(clientRes);
            },
          );

          upstreamReq.on("error", (error) => {
            if (!clientRes.headersSent) {
              clientRes.writeHead(502, { "content-type": "application/json" });
            }
            clientRes.end(JSON.stringify({ error: String(error && error.message ? error.message : error) }));
          });

          clientReq.pipe(upstreamReq);
        });

        server.listen(listenPort, listenHost, () => {
          console.log(`[pvl-ollama-proxy] ''${listenHost}:''${listenPort} -> ''${targetBase.href}`);
        });
      '';
    };

    files."run-opendesign.sh" = {
      mode = "0555";
      text = ''
        #!/bin/sh
        set -eu

        node /app/pvl-ollama-loopback-proxy.cjs &
        proxy_pid="$!"

        node apps/daemon/dist/cli.js --no-open &
        app_pid="$!"

        cleanup() {
          kill "$proxy_pid" "$app_pid" 2>/dev/null || true
          wait "$proxy_pid" "$app_pid" 2>/dev/null || true
        }

        trap cleanup INT TERM EXIT
        wait "$app_pid"
        status="$?"
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
        trap - INT TERM EXIT
        exit "$status"
      '';
    };
  };
}

{
  domain,
  secretNamespace ? "pvl",
  ...
} @ stack: let
  serviceRegistryLib = import ../flake/service-registry.nix;
  mkStack = import ./pvl-registry.nix;
  subDomain = subdomain: "${subdomain}.${domain}";
  secretsBase = ../../data/secrets + "/${secretNamespace}";
  secretsLabel = "data/secrets/${secretNamespace}";

  base = {
    inherit secretNamespace;
    activeEndpointGroup = stack.activeEndpointGroup or "home";
    constructor = mkStack;
    enableExternalConnectors = false;
    limits = {};
    org = "pvl";
    splitHorizonRole = "x2";
    tunnels = {};
    trustedCidrs = ["10.10.0.0/16" "10.89.0.0/16" "127.0.0.0/8"];
    stackBaseArgs = {
      defaultUser = "pvl";
      stackSecretsBasePath = secretsBase;
      stackSecretsLabel = secretsLabel;
      defaultClientSecretsBasePath = secretsBase + "/services";
      defaultNatsSecretsBasePath = secretsBase + "/nats";
      defaultPostgresSecretsBasePath = secretsBase + "/postgres";
      defaultVmstackSecretsBasePath = secretsBase + "/vmstack";
      defaultNginxSecretsBasePath = secretsBase + "/nginx";
      defaultCaCertAgeFile = secretsBase + "/ca/ca.crt.age";
      defaultCaCertHostPath = "/etc/ssl/certs/pvl-ca.crt";
      defaultCaCertContainerPath = "/run/secrets/pvl-ca.crt";
      defaultClientIdentitySuffix = domain;
      defaultExtServiceIdentitySuffix = domain;
      defaultSecretOwner = "pvl";
      defaultSecretGroup = "pvl";
      defaultServiceIdentitySuffix = "srv.z.${domain}";
      defaultPostgresUrl = "postgresql://postgres@127.0.0.1:5432/pvl?sslmode=verify-ca";
      defaultPostgresCaCertPath = "/run/agenix/pvl-ca-cert";
      defaultPostgresAfter = ["pvl-postgres.service"];
      defaultNatsUrl = "tls://127.0.0.1:4222";
      defaultNatsCaCertPath = "/run/agenix/pvl-ca-cert";
      defaultNatsAfter = ["pvl-nats.service"];
    };
  };

  data = rec {
    roles = {
      x2 = {
        host = "pvl-x2";
        octet = 10;
      };
    };

    endpointGroups = {
      home = {
        project = "pvl";
        address = "127.0.0.1";
        weight = 100;
      };
    };

    domains = {
      apex = [domain (subDomain "www")];
      beszel = [(subDomain "beszel")];
      docs = [(subDomain "docs") (subDomain "docmost-x")];
      immich = [(subDomain "photos")];
      memos = [(subDomain "memos-x")];
      open-webui = [(subDomain "chat")];
      portainer = [(subDomain "portainer")];
      vaultwarden = [(subDomain "vault") (subDomain "vaultwarden-x")];
    };

    services = {
      x2 = {
        beszel = {
          domain = "beszel";
          ports.http.port = 8090;
        };
        docmost = {
          domain = "docs";
          ports.http.port = 3000;
        };
        immich = {
          domain = "immich";
          ports.http.port = 2283;
        };
        memos = {
          domain = "memos";
          ports.http.port = 5230;
        };
        nginx.ports.http.port = 10800;
        ollama.ports.main.port = 11434;
        open-webui = {
          domain = "open-webui";
          ports.http.port = 4000;
        };
        portainer = {
          domain = "portainer";
          ports = {
            http.port = 8001;
            https.port = 9444;
          };
        };
        postgres.ports.main.port = 5432;
        shadowsocks.ports.main.port = 8388;
        vaultwarden = {
          domain = "vaultwarden";
          ports.http.port = 2000;
        };
      };
    };

    tunnelDomains = with domains; [
      apex
      beszel
      docs
      immich
      memos
      open-webui
      portainer
      vaultwarden
    ];
  };
in
  serviceRegistryLib.mkStackRegistry (stack // base // data)

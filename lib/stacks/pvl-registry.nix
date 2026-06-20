{
  stackName,
  env,
  domain,
  internalDomain,
  activeEndpointGroup ? "home",
  endpointSpecs ? {
    home = {
      project = "pvl";
      address = "127.0.0.1";
      weight = 100;
    };
  },
  secretNamespace ? "pvl",
  secretScope ? null,
  defaultMailDomain ? domain,
  extraDomains ? {},
  extraServiceSpecs ? {},
  extraTunnelDomains ? [],
}: let
  serviceRegistryLib = import ../flake/service-registry.nix;
  subDomain = subdomain: "${subdomain}.${domain}";
  secretsBase = ../../data/secrets + "/${secretNamespace}";
  secretsLabel = "data/secrets/${secretNamespace}";

  roleSpecs = {
    x2 = {
      host = "pvl-x2";
      octet = 10;
    };
  };
  roles = serviceRegistryLib.mkRoles roleSpecs;

  domains = serviceRegistryLib.mkDomains ({
      apex = [domain (subDomain "www")];
      beszel = [subDomain "beszel"];
      docs = [(subDomain "docs") (subDomain "docmost-x")];
      immich = [subDomain "photos"];
      memos = [subDomain "memos-x"];
      open-webui = [subDomain "chat"];
      portainer = [subDomain "portainer"];
      vaultwarden = [(subDomain "vault") (subDomain "vaultwarden-x")];
    }
    // extraDomains);
  extraServices = serviceRegistryLib.resolveExtraServices extraServiceSpecs {
    inherit domains roles;
  };

  services = {
    x2 = {
      beszel = {
        domain = domains.beszel;
        ports.http.port = 8090;
      };
      docmost = {
        domain = domains.docs;
        ports.http.port = 3000;
      };
      immich = {
        domain = domains.immich;
        ports.http.port = 2283;
      };
      memos = {
        domain = domains.memos;
        ports.http.port = 5230;
      };
      nginx = {
        ports.http.port = 10800;
      };
      ollama = {
        ports.main.port = 11434;
      };
      open-webui = {
        domain = domains.open-webui;
        ports.http.port = 4000;
      };
      portainer = {
        domain = domains.portainer;
        ports = {
          http.port = 8001;
          https.port = 9444;
        };
      };
      postgres = {
        ports.main.port = 5432;
      };
      shadowsocks = {
        ports.main.port = 8388;
      };
      vaultwarden = {
        domain = domains.vaultwarden;
        ports.http.port = 2000;
      };
    };
  };
  serviceSpecs = serviceRegistryLib.normalizeServices roles (serviceRegistryLib.mergeRoleServices services extraServices);
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
  resolvedTunnelDomains = tunnelDomains ++ [{hosts = extraTunnelDomains;}];

  serviceRegistry = serviceRegistryLib.mkServiceRegistry {
    inherit
      activeEndpointGroup
      domains
      serviceSpecs
      ;
    tunnelDomains = resolvedTunnelDomains;
    defaultEndpointSpecs = endpointSpecs;
    dnsRouteDomains = ["~${internalDomain}" "~${domain}"];
    internalDomain = internalDomain;
    roleHosts = serviceRegistryLib.roleHosts roles;
    roleOctets = serviceRegistryLib.roleOctets roles;
    trustedCidrs = ["10.10.0.0/16" "10.89.0.0/16" "127.0.0.0/8"];
  };

  base = import ../flake/stack/lib.nix {
    stackName = stackName;
    org = "pvl";
    env = env;
    defaultMailDomain = defaultMailDomain;
    publicDomain = domain;
    internalDomain = internalDomain;
    secretScope = secretScope;
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
in
  base
  // {
    inherit secretNamespace serviceRegistry;
  }

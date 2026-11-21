{pkgs}: let
  core = import ../../../ab/core;
  repoComponent = import ../../../ab/repo {inherit core;};
  stackComponent = import ../../../ab/stack {inherit core;};
  mkStackDefinition = stackName: extra:
    {
      env = "test";
      domain = "${stackName}.example.test";
      internalDomain = "${stackName}.internal";
      activeEndpointGroup = "live";
      endpointGroups.live = {
        weight = 100;
      };
      enableExternalConnectors = false;
      tunnels = {};
      instances.proxy = {};
      dependencies = {};
      network = {
        project = stackName;
        subnetId = 10;
        priority = 100;
      };
    }
    // extra;
  stackDefinitions = {
    platform = mkStackDefinition "platform" {
      instances = {
        proxy = {};
        db = {};
      };
      network.subnetId = 30;
    };
    app = mkStackDefinition "app" {
      ingress = {
        edgeTlsDomainNames = ["apex"];
        declarations.http.proxies.app = {
          service = "app";
          domain = "apex";
        };
      };
      secretScope = "dev";
      stateVolumeSize = "32GiB";
      instances = {
        proxy = {};
        web = {};
      };
      dependencies.db.stack = "platform";
      access.database = {
        to = {
          stack = "platform";
          role = "db";
        };
        tcp = [5432];
      };
    };
  };
  registryFor = definition: {
    roles = {
      proxy = {
        host = "proxy";
        octet = 10;
      };
      web = {
        host = "app-web";
        octet = 20;
      };
      db = {
        host = "platform-db";
        octet = 30;
      };
    };
    services = {
      proxy = {};
      web.app.ports.http.port = 8080;
      db.database.ports.main.port = 5432;
    };
    domains.apex = [definition.domain];
    tunnelDomains = [];
    limits = {};
  };
  baseDefaults = {
    fabric.addressBases = {
      ipv4 = "10.10";
      ipv6 = "fd42:1234:5678";
    };
    org = "test";
    identitySuffix = "service.test";
    postgres.url = "postgresql://postgres@db/test";
    nats.url = "nats://nats";
  };
  accountData = {
    rawUserdata = {};
    rawGroupData = {};
  };
  mkFamily = secrets:
    stackComponent.config.family {
      inherit accountData stackDefinitions registryFor;
      placementScopes.app-live = {
        stack = "app";
        placement = "live";
      };
      defaults = baseDefaults // {inherit secrets;};
    };
  family = mkFamily {
    directory = "/secrets";
    labelRoot = "secrets";
  };
  invalidTrailingSecretDirectory = builtins.tryEval (builtins.deepSeq (mkFamily {
      directory = "/secrets/";
      labelRoot = "secrets";
    })
    true);
  rootSecretDirectoryFamily = mkFamily {
    directory = /.;
    labelRoot = "secrets";
  };
  invalidSecretNamespaceOverride = builtins.tryEval (stackComponent.config.family {
    inherit accountData registryFor;
    stackDefinitions =
      stackDefinitions
      // {
        app = stackDefinitions.app // {secretNamespace = "shadow";};
      };
    defaults = {
      fabric.addressBases = {
        ipv4 = "10.10";
        ipv6 = "fd42:1234:5678";
      };
      org = "test";
      identitySuffix = "service.test";
      secrets = {
        directory = "/secrets";
        labelRoot = "secrets";
      };
    };
  });
  tryDefinitions = definitions:
    builtins.tryEval (builtins.deepSeq (stackComponent.config.family {
        inherit accountData registryFor;
        stackDefinitions = definitions;
        defaults = {
          fabric.addressBases = {
            ipv4 = "10.10";
            ipv6 = "fd42:1234:5678";
          };
          org = "test";
          identitySuffix = "service.test";
          secrets = {
            directory = "/secrets";
            labelRoot = "secrets";
          };
        };
      })
      true);
  invalidSecretNamespace = builtins.tryEval (builtins.deepSeq (stackComponent.config.family {
      inherit accountData stackDefinitions registryFor;
      defaults = {
        fabric.addressBases = {
          ipv4 = "10.10";
          ipv6 = "fd42:1234:5678";
        };
        org = "test";
        identitySuffix = "service.test";
        secrets = {
          namespace = "../escape";
          directory = "/secrets";
          labelRoot = "secrets";
        };
      };
    })
    true);
  tryDefaults = candidate:
    builtins.tryEval (builtins.deepSeq (stackComponent.config.family {
        inherit accountData registryFor stackDefinitions;
        defaults = candidate;
      })
      true);
  invalidDefaultField = tryDefaults (baseDefaults
    // {
      secrets = {
        directory = "/secrets";
        labelRoot = "secrets";
      };
      postgress.url = "postgresql://typo";
    });
  invalidNestedDefaultField = tryDefaults (baseDefaults
    // {
      secrets = {
        directory = "/secrets";
        labelRoot = "secrets";
      };
      postgres = baseDefaults.postgres // {typo = true;};
    });
  invalidPlacementScopeField = builtins.tryEval (builtins.deepSeq (stackComponent.config.family {
      inherit accountData registryFor stackDefinitions;
      defaults =
        baseDefaults
        // {
          secrets = {
            directory = "/secrets";
            labelRoot = "secrets";
          };
        };
      placementScopes.app-live = {
        stack = "app";
        placement = "live";
        typo = true;
      };
    })
    true);
  reservedDirectoryImport = builtins.tryEval (builtins.deepSeq (repoComponent.importDirectory ../../../config) true);
  authoredStackName = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {stackName = "app";};});
  unknownDefinitionField = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {typo = true;};});
  invalidStateVolumeSize = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {stateVolumeSize = 32;};});
  invalidDomainNames = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {domainNames = ["missing"];};});
  invalidIngressDomainNames = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {ingress.edgeTlsDomainNames = ["missing"];};});
  invalidIngressField = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {ingress.typo = true;};});
  invalidTunnelPublication = tryDefinitions (stackDefinitions
    // {
      app =
        stackDefinitions.app
        // {
          tunnels.publications.bad = {
            kind = "";
            hostNames = [];
          };
        };
    });
  ingressDeclarationRegistry = {
    roles.corp = {};
    services.app = {};
    domains = {
      apex = ["app.example.test"];
      backend = ["backend.example.test"];
    };
    limits = {
      httpReqBodyLimits.upload = "1g";
      timeouts.stream = "45s";
    };
    portFor = service: port:
      if service == "app" && port == "http"
      then 8080
      else throw "unknown port";
  };
  tryIngressDeclarations = declarations:
    builtins.tryEval (builtins.deepSeq (stackComponent.ingress.declarations {
        serviceRegistry = ingressDeclarationRegistry;
        inherit declarations;
      })
      true);
  invalidIngressDeclarationService = tryIngressDeclarations {
    http.proxies.app = {
      service = "missing";
      domain = "apex";
    };
  };
  invalidIngressDeclarationDomain = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "missing";
    };
  };
  invalidIngressDeclarationPolicy = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      policy.typo = true;
    };
  };
  validProxyRequestBody = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      requestBody.maxSize = "upload";
    };
  };
  invalidProxyRequestBodyLimit = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      requestBody.maxSize = "missing";
    };
  };
  validProxyResponse = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      response.buffering = "stream";
    };
  };
  validRouteResponse = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/stream";
      response.buffering = "stream";
    };
  };
  invalidResponseBuffering = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      response.buffering = "buffer";
    };
  };
  invalidEdgeAuthResponse = tryIngressDeclarations {
    http.routes.auth = {
      domain = "apex";
      path = "/auth";
      target = "edge-auth";
      response.buffering = "stream";
    };
  };
  validProxyTimeout = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      timeout = "stream";
    };
  };
  validRouteTimeout = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/stream";
      timeout = "stream";
    };
  };
  invalidTimeoutProfile = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      timeout = "missing";
    };
  };
  invalidEdgeAuthTimeout = tryIngressDeclarations {
    http.routes.auth = {
      domain = "apex";
      path = "/auth";
      target = "edge-auth";
      timeout = "stream";
    };
  };
  validProxyUpstreamRole = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      upstream.role = "corp";
    };
  };
  validRouteUpstreamRoleAndHost = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/proxy";
      upstream = {
        host = "backend";
        role = "corp";
      };
    };
  };
  invalidUpstreamRole = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      upstream.role = "missing";
    };
  };
  invalidUpstreamHostDomain = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/proxy";
      upstream.host = "missing";
    };
  };
  validRootRedirectUrl = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      rootRedirect = {
        status = 307;
        to = {
          scheme = "https";
          domain = "backend";
          path = "/admin/";
        };
      };
    };
  };
  invalidRootRedirectBoth = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      rootRedirect = {
        path = "/local";
        status = 307;
        to = {
          scheme = "https";
          domain = "backend";
          path = "/admin/";
        };
      };
    };
  };
  invalidRootRedirectNeither = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      rootRedirect.status = 307;
    };
  };
  validStructuredUpstreamRedirect = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      upstreamRedirects = [
        {
          source = {
            kind = "url";
            scheme = "http";
            domain = "backend";
          };
          preservePath = true;
          to = {
            scheme = "https";
            domain = "backend";
            path = "/";
          };
        }
      ];
    };
  };
  validRouteUpstreamRedirect = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/dav";
      upstreamRedirects = [
        {
          source.kind = "path";
          preservePath = true;
          to = {
            scheme = "https";
            domain = "backend";
            path = "/";
          };
        }
      ];
    };
  };
  invalidPreservePathTarget = tryIngressDeclarations {
    http.proxies.app = {
      service = "app";
      domain = "apex";
      upstreamRedirects = [
        {
          source.kind = "path";
          preservePath = true;
          to = {
            scheme = "https";
            domain = "backend";
            path = "/fixed";
          };
        }
      ];
    };
  };
  invalidEdgeAuthUpstreamRedirect = tryIngressDeclarations {
    http.routes.auth = {
      domain = "apex";
      path = "/auth";
      target = "edge-auth";
      upstreamRedirects = [
        {
          source.kind = "path";
          preservePath = true;
          to = {
            scheme = "https";
            domain = "backend";
            path = "/";
          };
        }
      ];
    };
  };
  validIngressRedirect = tryIngressDeclarations {
    http.redirects.app = {
      domain = "apex";
      status = 307;
      to = {
        service = "app";
        path = "/calendar";
      };
    };
  };
  invalidIngressRedirectService = tryIngressDeclarations {
    http.redirects.app = {
      domain = "apex";
      status = 307;
      to = {
        service = "missing";
        path = "/calendar";
      };
    };
  };
  invalidIngressRedirectStatus = tryIngressDeclarations {
    http.redirects.app = {
      domain = "apex";
      status = 200;
      to = {
        service = "app";
        path = "/calendar";
      };
    };
  };
  invalidIngressDeclarationRouteTarget = tryIngressDeclarations {
    http.routes.app = {
      domain = "apex";
      path = "/app";
      target = "unknown";
    };
  };
  invalidIngressDeclarationStreamProtocol = tryIngressDeclarations {
    stream.proxies.app = {
      service = "app";
      domain = "apex";
      port = "http";
      protocol = "sctp";
    };
  };
  invalidIngressDeclarationEdgeAuthBuffer = tryIngressDeclarations {
    http.routes.signout = {
      domain = "apex";
      path = "/signout";
      target = "edge-auth";
      responseHeaderBufferSize = "16k";
    };
  };
  validExactRouteMatch = tryIngressDeclarations {
    http.routes.callback = {
      service = "app";
      domain = "apex";
      path = "/";
      match = {
        kind = "exact";
        pattern = "/callback";
      };
    };
  };
  validRichIngressDeclaration = tryIngressDeclarations {
    http.routes.upload = {
      service = "app";
      domain = "apex";
      path = "/";
      match = {
        kind = "regex";
        pattern = "^/upload$";
      };
      policy = {
        auth = "edge";
        authBodyLimit = "upload";
        authCache = "no-cache";
        csp = "upstream";
      };
      requestBody = {
        buffering = "stream";
        maxSize = "upload";
      };
    };
  };
  invalidIngressDeclarationMatch = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/";
      match = {
        kind = "prefix";
        pattern = "/app";
      };
    };
  };
  invalidIngressDeclarationBodyLimit = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/";
      requestBody.maxSize = "missing";
    };
  };
  invalidIngressDeclarationAuthBodyLimit = tryIngressDeclarations {
    http.routes.app = {
      service = "app";
      domain = "apex";
      path = "/";
      policy.authBodyLimit = "upload";
    };
  };
  validStaticSiteDeclaration = tryIngressDeclarations {
    http.staticSites.docs = {
      hostNames = ["docs.example.test"];
      file = {
        path = ".well-known/policy.txt";
        content = "policy\n";
      };
    };
  };
  invalidStaticSitePath = tryIngressDeclarations {
    http.staticSites.docs = {
      hostNames = ["docs.example.test"];
      file = {
        path = "/policy.txt";
        content = "policy\n";
      };
    };
  };
  invalidStaticSiteHosts = tryIngressDeclarations {
    http.staticSites.docs = {
      hostNames = ["docs.example.test" "docs.example.test"];
      file = {
        path = "policy.txt";
        content = "policy\n";
      };
    };
  };
  validMultiFileStaticSite = tryIngressDeclarations {
    http.staticSites.docs = {
      domain = "backend";
      files = [
        {
          path = "policy.txt";
          content = "policy\n";
        }
        {
          path = ".well-known/policy.txt";
          content = "policy\n";
        }
      ];
      routes = [
        {
          domain = "apex";
          path = "/.well-known/docs";
        }
      ];
    };
  };
  invalidStaticSiteFileModes = tryIngressDeclarations {
    http.staticSites.docs = {
      domain = "backend";
      file = {
        path = "policy.txt";
        content = "policy\n";
      };
      files = [
        {
          path = "copy.txt";
          content = "copy\n";
        }
      ];
    };
  };
  invalidStaticSiteRouteDomain = tryIngressDeclarations {
    http.staticSites.docs = {
      domain = "backend";
      files = [
        {
          path = "policy.txt";
          content = "policy\n";
        }
      ];
      routes = [
        {
          domain = "missing";
          path = "/docs";
        }
      ];
    };
  };
  invalidStaticSiteRouteRoot = tryIngressDeclarations {
    http.staticSites.docs = {
      domain = "backend";
      files = [
        {
          path = "policy.txt";
          content = "policy\n";
        }
      ];
      routes = [
        {
          domain = "apex";
          path = "/";
        }
      ];
    };
  };
  overlappingRole = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {dependencies.web.stack = "platform";};});
  unknownRoleField = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {instances.web.typo = true;};});
  prebuiltConfigFamily = stackComponent.config.prebuiltFamily {
    stacks.legacy.name = "legacy";
  };
  invalidPrebuiltConfigFamily = builtins.tryEval (stackComponent.config.prebuiltFamily {
    stacks.legacy.name = "other";
  });
  inherit (family) stacks;
in
  assert builtins.attrNames stacks == ["app" "platform"];
  assert !invalidSecretNamespaceOverride.success;
  assert !authoredStackName.success;
  assert !unknownDefinitionField.success;
  assert !overlappingRole.success;
  assert !unknownRoleField.success;
  assert !invalidSecretNamespace.success;
  assert !invalidDefaultField.success;
  assert !invalidNestedDefaultField.success;
  assert !invalidPlacementScopeField.success;
  assert !reservedDirectoryImport.success;
  assert !invalidStateVolumeSize.success;
  assert !invalidDomainNames.success;
  assert !invalidIngressDomainNames.success;
  assert !invalidIngressField.success;
  assert !invalidTunnelPublication.success;
  assert !invalidIngressDeclarationService.success;
  assert !invalidIngressDeclarationDomain.success;
  assert !invalidIngressDeclarationPolicy.success;
  assert validProxyRequestBody.success;
  assert !invalidProxyRequestBodyLimit.success;
  assert validProxyResponse.success;
  assert validRouteResponse.success;
  assert !invalidResponseBuffering.success;
  assert !invalidEdgeAuthResponse.success;
  assert validProxyTimeout.success;
  assert validRouteTimeout.success;
  assert !invalidTimeoutProfile.success;
  assert !invalidEdgeAuthTimeout.success;
  assert validProxyUpstreamRole.success;
  assert validRouteUpstreamRoleAndHost.success;
  assert !invalidUpstreamRole.success;
  assert !invalidUpstreamHostDomain.success;
  assert validRootRedirectUrl.success;
  assert !invalidRootRedirectBoth.success;
  assert !invalidRootRedirectNeither.success;
  assert validStructuredUpstreamRedirect.success;
  assert validRouteUpstreamRedirect.success;
  assert !invalidPreservePathTarget.success;
  assert !invalidEdgeAuthUpstreamRedirect.success;
  assert validIngressRedirect.success;
  assert !invalidIngressRedirectService.success;
  assert !invalidIngressRedirectStatus.success;
  assert !invalidIngressDeclarationRouteTarget.success;
  assert !invalidIngressDeclarationStreamProtocol.success;
  assert !invalidIngressDeclarationEdgeAuthBuffer.success;
  assert validExactRouteMatch.success;
  assert validRichIngressDeclaration.success;
  assert !invalidIngressDeclarationMatch.success;
  assert !invalidIngressDeclarationBodyLimit.success;
  assert !invalidIngressDeclarationAuthBodyLimit.success;
  assert validStaticSiteDeclaration.success;
  assert !invalidStaticSitePath.success;
  assert !invalidStaticSiteHosts.success;
  assert validMultiFileStaticSite.success;
  assert !invalidStaticSiteFileModes.success;
  assert !invalidStaticSiteRouteDomain.success;
  assert !invalidStaticSiteRouteRoot.success;
  assert !invalidTrailingSecretDirectory.success;
  assert prebuiltConfigFamily.stacks.legacy.name == "legacy";
  assert !invalidPrebuiltConfigFamily.success;
  assert stacks.app.name == "app";
  assert stacks.app.environment == "test";
  assert !(stacks.app ? stackName);
  assert !(stacks.app ? env);
  assert stacks.app.domains
  == {
    public = "app.example.test";
    internal = "app.internal";
  };
  assert stacks.app.mail.domain == "app.example.test";
  assert stacks.app.mail.noReplyFor "probe" == "no-reply+probe@app.example.test";
  assert stacks.app.ingress.edgeTls.hosts == ["app.example.test"];
  assert stacks.app.ingress.declarations.http.proxies.app
  == {
    service = "app";
    domain = "apex";
    port = "http";
    rootRedirect = null;
    policy = {
      auth = null;
      csp = null;
      rateLimit = "web";
    };
  };
  assert stacks.app.ingress.internalTls.clientCidrs
  == {
    ipv4 = ["10.10.10.0/24" "10.10.30.0/24"];
    ipv6 = ["fd42:1234:5678:10::/64" "fd42:1234:5678:30::/64"];
  };
  assert !(stacks.app.serviceRegistry ? tunnelHosts);
  assert stacks.app.tunnels.hosts == [];
  assert builtins.all (name: !(builtins.hasAttr name stacks.app)) [
    "org"
    "defaultMailDomain"
    "publicDomain"
    "internalDomain"
    "noReplyEmailFor"
  ];
  assert builtins.attrNames stacks.app.accounts == ["groupSets" "groups" "helpers" "meta" "nixosModule" "userSets" "users"];
  assert builtins.attrNames stacks.app.accounts.userSets == ["active" "activeIds" "disabled" "disabledIds"];
  assert builtins.attrNames stacks.app.accounts.groupSets == ["hasAnyGroup" "hasGroup" "members" "names" "namesForUserIds" "userIdsIn"];
  assert builtins.attrNames stacks.app.accounts.meta == ["defaultMailDomain" "includeAllStacks" "stackName"];
  assert builtins.isFunction stacks.app.accounts.nixosModule;
  assert stacks.app.accounts.helpers.isAccounts stacks.app.accounts;
  assert !(stacks.app.accounts.helpers.isAccounts (builtins.removeAttrs stacks.app.accounts ["meta"]));
  assert !(stacks.app ? users);
  assert family.projectionScopes.app-live
  == {
    stack = "app";
    placement = "live";
  };
  assert family.projections == {};
  assert stacks.app.secrets.namespace == "test";
  assert stacks.app.secrets.scope == "dev";
  assert !(stacks.app ? secretNamespace);
  assert !(stacks.app ? secretScope);
  assert !(stacks.app ? defaultNginxSecretsBase);
  assert !(stacks.app ? defaultNginxSecretsBasePath);
  assert stacks.app.infra.incus == {stateVolumeSize = "32GiB";};
  assert builtins.attrNames stacks.app.topology.instances == ["proxy" "web"];
  assert builtins.attrNames stacks.app.serviceRegistry.roles == ["db" "proxy" "web"];
  assert stacks.app.topology.instances.web.role == "web";
  assert stacks.app.topology.instances.web.host == "app-web";
  assert stacks.app.topology.instances.web.resourceId == "app.app-web";
  assert stacks.app.topology.instances.web.address == "10.10.10.20";
  assert toString stacks.app.secrets.base == "/secrets/test";
  assert stacks.app.secrets.labelBase == "secrets/test";
  assert toString rootSecretDirectoryFamily.stacks.app.secrets.base == "/test";
  assert stacks.app.topology.dependencies.db.endpoint.addresses.ipv4 == "10.10.30.30";
  assert builtins.length stacks.app.network.access == 1;
  assert builtins.all (rule: rule.source.fabric == "app" && rule.destination.fabric == "platform" && rule.tcpPorts == [5432]) stacks.app.network.access;
  assert stacks.app.network.externalConnectors == false;
  assert stacks.app.network.enabledFamilies == ["ipv4" "ipv6"];
  assert stacks.app.network.preferredServiceFamily == "ipv4";
  assert stacks.app.network.prefixes
  == {
    ipv4 = "10.10.10.0/24";
    ipv6 = "fd42:1234:5678:10::/64";
  };
  assert stacks.app.topology.dependencies.db.endpoint.addresses.ipv6 == "fd42:1234:5678:30::30";
  assert !(stacks.app ? placements);
  assert builtins.attrNames stacks.app.topology.placements == ["live"];
  assert !(stacks.app.topology.placements.live ? placements);
  assert !(stacks.app.topology.placements.live.topology ? placements);
  assert stacks.app.topology.placements.live.network.project == "app";
    pkgs.runCommand "config-family-test" {} ''
      touch "$out"
    ''

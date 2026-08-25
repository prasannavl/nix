{pkgs}: let
  lib = pkgs.lib;
  nginx = import ../services/nginx {lib = lib;};
  nginxBaseConfig = builtins.readFile ../services/nginx/compose/nginx.conf;
  mkStack = serviceRoles: let
    roleHosts = {
      proxy = "proxy-system";
      source = "source-system";
      target = "target-system";
    };
    stack = {
      stackName = "demo";
      serviceRegistry = {
        roles = lib.mapAttrs (_: host: {inherit host;}) roleHosts;
        services = lib.mapAttrs (service: role: {inherit role service;}) serviceRoles;
        domains = {
          api = ["api.example.test"];
          app = ["app.example.test"];
        };
        serviceFor = service: stack.serviceRegistry.services.${service};
      };
      withServiceRoles = overrides: mkStack (serviceRoles // overrides);
    };
  in
    stack;
  stack = mkStack {
    api = "target";
    app = "target";
  };
  routeSetFor = projectedStack: {
    projectedNginx = nginx;
    projectedRegistry = projectedStack.serviceRegistry;
    routes = {
      proxyVhosts =
        lib.mapAttrs
        (service: spec: {
          serverNames = projectedStack.serviceRegistry.domains.${service};
          upstreams = [projectedStack.serviceRegistry.roles.${spec.role}.host];
        })
        projectedStack.serviceRegistry.services;
      nginxRoutes = {};
      redirectVhosts = {};
      staticSites = {};
    };
  };
  projection = {
    effects = [
      {
        kind = "route_profile";
        scope = "demo";
        service = "app";
        profile = "app@host:target-system";
        baseline_profile = "app@host:source-system";
        executor_host = "proxy";
        executor_host_resource = "host:proxy-system";
        executor_resource = "service:nginx";
        profiles = [
          {
            profile = "app@host:source-system";
            endpoint_host = "source";
            endpoint_host_resource = "host:source-system";
            resource = "service:app";
          }
          {
            profile = "app@host:target-system";
            endpoint_host = "target";
            endpoint_host_resource = "host:target-system";
            resource = "service:app";
          }
        ];
      }
    ];
  };
  result = import ../services/nginx/phase-projection-routes.nix {
    inherit lib routeSetFor stack;
    phaseProjections = [projection];
    executorHostResource = "host:proxy-system";
    executorResource = "service:nginx";
    serverNamesFor = registry: service: registry.domains.${service};
    renderProfile = _: routes: builtins.toJSON routes;
    routePathFor = service: "/var/lib/routes/${service}.conf";
    validationArgvFor = _: ["/bin/true"];
    reloadServices = [];
  };
  renderedRouteSetFor = projectedStack: let
    endpointForHost = {
      proxy-system = "127.0.0.2:8080";
      source-system = "127.0.0.3:8080";
      target-system = "127.0.0.4:8080";
    };
  in {
    projectedNginx = nginx;
    projectedRegistry = projectedStack.serviceRegistry;
    routes = {
      proxyVhosts =
        lib.mapAttrs
        (service: spec: {
          serverNames = projectedStack.serviceRegistry.domains.${service};
          upstreams = [endpointForHost.${projectedStack.serviceRegistry.roles.${spec.role}.host}];
          rateLimit = nginx.rateLimitProfiles.default;
        })
        projectedStack.serviceRegistry.services;
      nginxRoutes = {};
      redirectVhosts = {};
      staticSites = {};
    };
  };
  renderComposableProfile = _: routes:
    lib.concatStringsSep "\n" [
      (nginx.renderServers ({
          includeSharedHttpPreamble = false;
          listenDirectives = ["listen 8080;"];
        }
        // routes))
      (nginx.renderTlsServers ({
          certPath = "/run/test/internal.crt";
          keyPath = "/run/test/internal.key";
          deferCertificateLoad = true;
          certPathVariable = "test_internal_certificate";
          keyPathVariable = "test_internal_certificate_key";
          listenPort = 8443;
          includeTlsPreamble = false;
        }
        // routes))
      (nginx.renderTlsServers ({
          certPath = "/run/test/edge.crt";
          keyPath = "/run/test/edge.key";
          deferCertificateLoad = true;
          certPathVariable = "test_edge_certificate";
          keyPathVariable = "test_edge_certificate_key";
          listenPort = 9443;
          rejectUnknownServerNames = true;
          includeTlsPreamble = false;
        }
        // routes))
    ];
  renderedResult = import ../services/nginx/phase-projection-routes.nix {
    inherit lib stack;
    routeSetFor = renderedRouteSetFor;
    phaseProjections = [projection];
    executorHostResource = "host:proxy-system";
    executorResource = "service:nginx";
    serverNamesFor = registry: service: registry.domains.${service};
    renderProfile = renderComposableProfile;
    routePathFor = service: "/var/lib/routes/${service}.conf";
    validationArgvFor = _: ["/bin/true"];
    reloadServices = [];
  };
  sharedPreamble =
    nginx.renderHttpSharedPreamble
    + nginx.renderTlsPreamble {
      certPath = "/run/test/internal.crt";
      keyPath = "/run/test/internal.key";
      deferCertificateLoad = true;
      certPathVariable = "test_internal_certificate";
      keyPathVariable = "test_internal_certificate_key";
      listenPort = 8443;
    }
    + nginx.renderTlsPreamble {
      certPath = "/run/test/edge.crt";
      keyPath = "/run/test/edge.key";
      deferCertificateLoad = true;
      certPathVariable = "test_edge_certificate";
      keyPathVariable = "test_edge_certificate_key";
      listenPort = 9443;
      rejectUnknownServerNames = true;
    };
  bootstrapContent = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: file: file.content) renderedResult.bootstrapFiles);
  composedContent = sharedPreamble + bootstrapContent;
  countOccurrences = needle: value: builtins.length (lib.splitString needle value) - 1;
  emptySecurityInclude = pkgs.writeText "empty-http-security.conf" "";
  syntaxCheckedContent =
    builtins.replaceStrings
    ["/etc/nginx/conf.d/lib/http-security.conf"]
    [(toString emptySecurityInclude)]
    composedContent;
  nginxConfig = pkgs.writeText "composable-phase-routes-nginx.conf" ''
    error_log stderr;
    pid /tmp/nginx-phase-projection-routes.pid;
    events {}
    http {
      access_log off;
      map $http_upgrade $connection_upgrade {
        default upgrade;
        "" close;
      }
      map $http_x_forwarded_host $forwarded_host_effective {
        default $http_x_forwarded_host;
        "" $host;
      }
      map $http_x_forwarded_proto $forwarded_proto_effective {
        default $scheme;
      }
      map $http_x_forwarded_port $forwarded_port_effective {
        default $server_port;
      }
      ${syntaxCheckedContent}
    }
  '';
in
  assert result.projectableServices == ["api" "app"];
  assert lib.hasInfix "include /etc/nginx/conf.d/phase-route-*.conf;" nginxBaseConfig;
  assert result.ordinaryRoutes.proxyVhosts == {};
  assert builtins.length (builtins.attrNames result.fileStates) == 6;
  assert lib.hasInfix "source-system" result.bootstrapFiles.app.content;
  assert result.bootstrapFiles.app.preserve;
  assert lib.hasInfix "target-system" result.bootstrapFiles.api.content;
  assert !result.bootstrapFiles.api.preserve;
  assert lib.hasInfix "target-system" result.fileStates."app@host:target-system".content;
  assert builtins.length result.fileStates."app@host:target-system".acceptedPreviousSha256 == 2;
  assert countOccurrences "map $remote_addr $client_addr_prefix_key {" composedContent == 1;
  assert countOccurrences "map $ssl_server_name $test_internal_certificate {" composedContent == 1;
  assert countOccurrences "map $ssl_server_name $test_internal_certificate_key {" composedContent == 1;
  assert countOccurrences "map $ssl_server_name $test_edge_certificate {" composedContent == 1;
  assert countOccurrences "map $ssl_server_name $test_edge_certificate_key {" composedContent == 1;
  assert countOccurrences "listen 9443 ssl default_server;" composedContent == 1;
  assert lib.all
  (file:
    !lib.hasInfix "map $remote_addr $client_addr_prefix_key {" file.content
    && !lib.hasInfix "map $ssl_server_name" file.content
    && !lib.hasInfix "default_server" file.content)
  (builtins.attrValues renderedResult.bootstrapFiles);
    pkgs.runCommand "nginx-phase-projection-routes-test" {} ''
      ${lib.getExe pkgs.nginx} -t -e stderr -c ${nginxConfig} -p "$PWD"
      touch "$out"
    ''

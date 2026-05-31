{lib}: let
  exposedPortsLib = import ../exposed-ports {inherit lib;};
  rateLimitProfiles = {
    default = exposedPortsLib.defaultRateLimitProfile;
    web =
      exposedPortsLib.defaultRateLimitProfile
      // {
        requestsPerSecond = 30;
        requestsPerSecondBurst = 300;
        requestsPerMinute = null;
        requestsPerMinuteBurst = null;
      };
  };
  mkProxyTimeout = value:
    if builtins.isAttrs value
    then {
      proxyReadTimeout = value.read;
      proxySendTimeout = value.send;
    }
    else {
      proxyReadTimeout = value;
      proxySendTimeout = value;
    };
  mkProxyTimeouts = values: builtins.mapAttrs (_: mkProxyTimeout) values;
  redirectStatusType = lib.types.enum [
    301
    302
    303
    307
    308
  ];
  rootRedirectTypeDef = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Path to redirect exact root requests to.";
      };

      status = lib.mkOption {
        type = redirectStatusType;
        default = 307;
        description = "HTTP redirect status for exact root requests.";
      };
    };
  };
  redirectVhostTypeDef = lib.types.submodule {
    options = {
      serverNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Hostname(s) served by this nginx redirect vhost.";
      };

      target = lib.mkOption {
        type = lib.types.str;
        description = "Absolute URL or path nginx should redirect all requests to.";
      };

      status = lib.mkOption {
        type = redirectStatusType;
        default = 307;
        description = "HTTP redirect status for requests to this vhost.";
      };

      preserveQuery = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to append the incoming query string to the redirect target.";
      };
    };
  };
  proxyVhostTypeDef = lib.types.submodule {
    options = {
      service = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Compose service name nginx should depend on for this vhost.";
      };

      serverNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Hostname(s) served by this nginx proxy vhost.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "Local backend port nginx should forward to.";
      };

      upstreams = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Backend server addresses (host:port).";
      };

      upstreamProtocol = lib.mkOption {
        type = lib.types.enum [
          "http"
          "https"
        ];
        default = "http";
        description = "Protocol nginx should use when proxying to this backend.";
      };

      upstreamHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional origin host for the Host header when proxying to this backend.";
      };

      upstreamTlsName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "auto";
        description = "TLS SNI name for HTTPS upstreams. \"auto\" derives it from upstreamHost when upstreamHost is host-only; null disables SNI.";
      };

      upstreamCaCertificate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "CA bundle nginx should use to verify HTTPS upstream certificates. When null, upstream certificate verification is not enabled by this renderer.";
      };

      prependPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional fixed path prefix to prepend when proxying to this backend.";
      };

      rootRedirect = lib.mkOption {
        type = lib.types.nullOr rootRedirectTypeDef;
        default = null;
        description = "Optional redirect for exact root requests before proxying other paths.";
      };

      rateLimit = lib.mkOption {
        type = lib.types.nullOr exposedPortsLib.rateLimitProfileType;
        default = null;
        description = "Optional resolved ingress rate-limiting policy for this proxy vhost.";
      };

      useUpstreamCsp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, suppress nginx's global Content-Security-Policy for this vhost and let the upstream's CSP pass through. Other security headers remain applied.";
      };

      useUpstreamReferrer = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, suppress nginx's global Referrer-Policy for this vhost and let the upstream's Referrer-Policy pass through. Other security headers remain applied.";
      };

      useUpstreamPermissionsPolicy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, suppress nginx's global Permissions-Policy for this vhost and let the upstream's Permissions-Policy pass through. Other security headers remain applied.";
      };

      proxyBufferSize = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx proxy_buffer_size override for large upstream response headers.";
      };

      proxyBuffering = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Optional nginx proxy_buffering override for streaming upstream responses.";
      };

      proxyReadTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx proxy_read_timeout override for long-running upstream responses.";
      };

      proxySendTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx proxy_send_timeout override for long-running upstream requests.";
      };

      clientMaxBodySize = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx client_max_body_size override for uploads to this vhost.";
      };

      proxyCookiePath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional replacement path for nginx proxy_cookie_path. Defaults to the served route prefix.";
      };

      proxyRedirects = lib.mkOption {
        type = lib.types.listOf proxyRedirectTypeDef;
        default = [];
        description = "Additional nginx proxy_redirect rewrites to apply before the default path-preserving redirect rewrite.";
      };

      authRequest = lib.mkOption {
        type = lib.types.nullOr authRequestTypeDef;
        default = null;
        description = "Optional nginx auth_request integration for this proxy vhost.";
      };
    };
  };

  authRequestTypeDef = lib.types.submodule {
    options = {
      provider = lib.mkOption {
        type = lib.types.enum ["oauth2-proxy"];
        default = "oauth2-proxy";
        description = "Forward-auth provider implementation.";
      };

      upstream = lib.mkOption {
        type = lib.types.str;
        default = "oauth2-proxy:4180";
        description = "Plain host:port for the auth provider nginx should proxy to.";
      };

      resolver = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx resolver directive value used to resolve the auth provider at request time.";
      };

      externalScheme = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional externally visible URL scheme for auth redirects and forwarded scheme headers.";
      };

      prefix = lib.mkOption {
        type = lib.types.str;
        default = "/oauth2";
        description = "Path prefix mounted for the auth provider callbacks and sign-in flow.";
      };

      passHeaders = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to forward authenticated identity headers to the upstream.";
      };

      clientMaxBodySize = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx client_max_body_size override for the internal auth request location.";
      };
    };
  };

  proxyRedirectTypeDef = lib.types.submodule {
    options = {
      from = lib.mkOption {
        type = lib.types.str;
        description = "Upstream Location value or nginx proxy_redirect pattern to rewrite.";
      };

      to = lib.mkOption {
        type = lib.types.str;
        description = "Replacement Location value for nginx proxy_redirect.";
      };
    };
  };

  routeTypeDef = lib.types.submodule {
    options = {
      service = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Compose service name nginx should depend on for this route.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [
          "static"
          "upstream"
        ];
        description = "Whether this route proxies to an upstream backend or a static site tree.";
      };

      serverName = lib.mkOption {
        type = lib.types.str;
        description = "Hostname served by this nginx route.";
      };

      path = lib.mkOption {
        type = lib.types.str;
        description = "Path prefix on the host vhost that nginx should mount.";
      };

      location = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional full nginx location match expression, such as '= /api/upload' or '~ ^/api/.*/upload$'. When set, path is still used for route-local rewrite and cookie path defaults.";
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Optional local backend port nginx should forward to.";
      };

      upstreams = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Backend server addresses (host:port).";
      };

      resolver = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx resolver directive value used to resolve this route's single upstream at request time.";
      };

      upstreamProtocol = lib.mkOption {
        type = lib.types.enum [
          "http"
          "https"
        ];
        default = "http";
        description = "Protocol nginx should use when proxying to this backend route.";
      };

      upstreamHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional origin host for the Host header when proxying to this backend route.";
      };

      upstreamTlsName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "auto";
        description = "TLS SNI name for HTTPS upstream routes. \"auto\" derives it from upstreamHost when upstreamHost is host-only; null disables SNI.";
      };

      upstreamCaCertificate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "CA bundle nginx should use to verify HTTPS upstream route certificates. When null, upstream certificate verification is not enabled by this renderer.";
      };

      prependPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional fixed path prefix to prepend when proxying to this backend route.";
      };

      stripPath = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether nginx should strip the configured path prefix before proxying to the backend.";
      };

      siteMountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Mounted static-site directory for static routes.";
      };

      siteIndex = lib.mkOption {
        type = lib.types.str;
        default = "index.html";
        description = "Index file name for static routes.";
      };

      siteSinglePageApp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether static routes should fall back to their index file for unknown paths.";
      };

      rateLimit = lib.mkOption {
        type = lib.types.nullOr exposedPortsLib.rateLimitProfileType;
        default = null;
        description = "Optional resolved ingress rate-limiting policy for this route.";
      };

      useUpstreamCsp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, suppress nginx's global Content-Security-Policy for this route and let the upstream's CSP pass through. Other security headers remain applied.";
      };

      useUpstreamReferrer = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, suppress nginx's global Referrer-Policy for this route and let the upstream's Referrer-Policy pass through. Other security headers remain applied.";
      };

      useUpstreamPermissionsPolicy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, suppress nginx's global Permissions-Policy for this route and let the upstream's Permissions-Policy pass through. Other security headers remain applied.";
      };

      proxyBufferSize = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx proxy_buffer_size override for large upstream response headers.";
      };

      proxyBuffering = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Optional nginx proxy_buffering override for streaming upstream responses.";
      };

      proxyReadTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx proxy_read_timeout override for long-running upstream responses.";
      };

      proxySendTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx proxy_send_timeout override for long-running upstream requests.";
      };

      proxyRequestBuffering = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Optional nginx proxy_request_buffering override for streaming large request bodies to the upstream.";
      };

      clientMaxBodySize = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional nginx client_max_body_size override for uploads to this route.";
      };

      proxyCookiePath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional replacement path for nginx proxy_cookie_path. Defaults to the served route prefix.";
      };

      proxyRedirects = lib.mkOption {
        type = lib.types.listOf proxyRedirectTypeDef;
        default = [];
        description = "Additional nginx proxy_redirect rewrites to apply before the default path-preserving redirect rewrite.";
      };

      authRequest = lib.mkOption {
        type = lib.types.nullOr authRequestTypeDef;
        default = null;
        description = "Optional nginx auth_request integration for this route.";
      };
    };
  };

  streamProxyTypeDef = lib.types.submodule {
    options = {
      listenPort = lib.mkOption {
        type = lib.types.port;
        description = "Host/container port nginx stream should listen on.";
      };

      protocol = lib.mkOption {
        type = lib.types.enum [
          "tcp"
          "udp"
        ];
        default = "tcp";
        description = "Transport protocol for this nginx stream proxy.";
      };

      upstreams = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Plain upstream host:port nginx stream should proxy to.";
      };

      serverNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Optional TLS SNI names for this stream proxy.";
      };
    };
  };

  upstreamHeaderFlags = src: {
    useUpstreamCsp = src.useUpstreamCsp or false;
    useUpstreamReferrer = src.useUpstreamReferrer or false;
    useUpstreamPermissionsPolicy = src.useUpstreamPermissionsPolicy or false;
  };

  isStreamProtocol = protocol: protocol == "tcp" || protocol == "udp";

  # When a location opts any security header out to the upstream, nginx's
  # replace-not-merge add_header inheritance means we must re-declare every
  # non-opted-out header at location scope. X-Content-Type-Options is always
  # re-declared; the rest are included only when not opted out.
  mkLocationSecurityHeaderIncludes = src: let
    flags = upstreamHeaderFlags src;
    anyOptOut =
      flags.useUpstreamCsp
      || flags.useUpstreamReferrer
      || flags.useUpstreamPermissionsPolicy;
    include = file: "        include /etc/nginx/conf.d/lib/${file};\n";
  in
    lib.optionalString anyOptOut (
      include "http-security-xcto.conf"
      + lib.optionalString (!flags.useUpstreamReferrer) (include "http-security-referrer.conf")
      + lib.optionalString (!flags.useUpstreamPermissionsPolicy) (include "http-security-permissions.conf")
      + lib.optionalString (!flags.useUpstreamCsp) (include "http-security-csp.conf")
    );

  mkProxyVhost = {defaultHost ? "localhost"}: serviceName: portName: portCfg: let
    nginxHostNames = portCfg.nginxHostNames or [];
    upstreamProtocol = portCfg.upstreamProtocol or "http";
    upstreams =
      if (portCfg.upstreams or null) != null
      then portCfg.upstreams
      else ["${defaultHost}:${toString portCfg.port}"];
  in
    lib.optionalAttrs (nginxHostNames != [] && ! isStreamProtocol upstreamProtocol) {
      "${serviceName}-${portName}" =
        {
          service = serviceName;
          inherit (portCfg) port;
          serverNames = nginxHostNames;
          upstreams = upstreams;
          inherit (portCfg) upstreamProtocol upstreamHost upstreamTlsName upstreamCaCertificate;
          rootRedirect = portCfg.rootRedirect or null;
          rateLimit = resolveRateLimit (portCfg.rateLimit or null);
          proxyBufferSize = portCfg.proxyBufferSize or null;
          proxyBuffering = portCfg.proxyBuffering or null;
          proxyReadTimeout = portCfg.proxyReadTimeout or null;
          proxySendTimeout = portCfg.proxySendTimeout or null;
          clientMaxBodySize = portCfg.clientMaxBodySize or null;
          proxyCookiePath = portCfg.proxyCookiePath or null;
          proxyRedirects = portCfg.proxyRedirects or [];
          authRequest = portCfg.authRequest or null;
        }
        // upstreamHeaderFlags portCfg;
    };

  sanitizeName = value:
    builtins.replaceStrings
    [
      "."
      "/"
      "*"
      ":"
      " "
    ]
    [
      "_"
      "_"
      "_"
      "_"
      "_"
    ]
    value;

  sanitizeVariableName = value:
    builtins.replaceStrings ["-"] ["_"] (sanitizeName value);

  normalizeRoutePath = path:
    if path == "/"
    then "/"
    else lib.removeSuffix "/" path;

  validatePlainUpstreamValue = fieldName: value:
    if lib.hasPrefix "http://" value || lib.hasPrefix "https://" value
    then throw "${fieldName} must be a plain host or host:port value without http:// or https://: ${value}"
    else if lib.hasInfix "/" value
    then throw "${fieldName} must not include a path component: ${value}"
    else value;

  validateTlsNameValue = fieldName: value:
    if value == ""
    then throw "${fieldName} must not be an empty string; use \"auto\" or null."
    else if lib.hasPrefix "http://" value || lib.hasPrefix "https://" value
    then throw "${fieldName} must be a plain hostname without http:// or https://: ${value}"
    else if lib.hasInfix "/" value
    then throw "${fieldName} must not include a path component: ${value}"
    else if lib.hasInfix ":" value
    then throw "${fieldName} must be a hostname without a port: ${value}"
    else value;

  resolveUpstreamTlsName = {
    upstreamProtocol,
    upstreamHost,
    upstreamTlsName,
  }:
    if upstreamProtocol != "https" || upstreamTlsName == null
    then null
    else if upstreamTlsName == "auto"
    then
      if upstreamHost == null
      then null
      else validateTlsNameValue "upstreamTlsName derived from upstreamHost" upstreamHost
    else validateTlsNameValue "upstreamTlsName" upstreamTlsName;

  normalizeUpstreamPathPrefix = value:
    if value == null
    then null
    else let
      normalized =
        if value == "/"
        then null
        else if lib.hasPrefix "/" value
        then lib.removeSuffix "/" value
        else lib.removeSuffix "/" "/${value}";
    in
      normalized;

  mkDynamicRoutes = {defaultHost ? "localhost"}: serviceName: portName: portCfg:
    lib.listToAttrs
    (map
      (route: let
        normalizedPath = normalizeRoutePath route.path;
        routeName = "${serviceName}-${portName}-${sanitizeName route.serverName}-${sanitizeName normalizedPath}";
        upstreams =
          if (portCfg.upstreams or null) != null
          then portCfg.upstreams
          else ["${defaultHost}:${toString portCfg.port}"];
        routeRateLimit =
          if route.rateLimit != null
          then route.rateLimit
          else portCfg.rateLimit or null;
      in
        assert lib.hasPrefix "/" normalizedPath;
        assert normalizedPath != "/"; {
          name = routeName;
          value =
            {
              service = serviceName;
              mode = "upstream";
              serverName = route.serverName;
              path = normalizedPath;
              location = route.location or null;
              inherit (portCfg) port;
              upstreams = upstreams;
              inherit (portCfg) upstreamProtocol upstreamHost upstreamTlsName upstreamCaCertificate;
              prependPath = null;
              stripPath = route.stripPath;
              rateLimit = resolveRateLimit routeRateLimit;
              proxyBufferSize = route.proxyBufferSize or (portCfg.proxyBufferSize or null);
              proxyBuffering = route.proxyBuffering or (portCfg.proxyBuffering or null);
              proxyReadTimeout = route.proxyReadTimeout or (portCfg.proxyReadTimeout or null);
              proxySendTimeout = route.proxySendTimeout or (portCfg.proxySendTimeout or null);
              proxyRequestBuffering = route.proxyRequestBuffering or null;
              clientMaxBodySize = route.clientMaxBodySize or (portCfg.clientMaxBodySize or null);
              proxyCookiePath = route.proxyCookiePath or null;
              proxyRedirects = route.proxyRedirects or [];
              authRequest = route.authRequest or (portCfg.authRequest or null);
            }
            // upstreamHeaderFlags route;
        })
      (portCfg.nginxRoutes or []));

  mkUpstreamBlock = name: upstreams:
    lib.concatStrings
    [
      "upstream ${name} {\n"
      "    ${lib.concatMapStringsSep "\n    " (s: "server ${validatePlainUpstreamValue "nginx upstream server" s};") upstreams}\n"
      "}\n"
    ];

  mkStreamUpstreamBlock = name: upstreams:
    lib.concatStrings
    [
      "upstream ${name} {\n"
      "    ${lib.concatMapStringsSep "\n    " (s: "server ${validatePlainUpstreamValue "nginx stream upstream server" s};") upstreams}\n"
      "}\n"
    ];

  mkStreamProxyServer = name: proxy: let
    listenProtocolSuffix =
      if proxy.protocol == "udp"
      then " udp"
      else "";
    proxyPassTarget = "stream_${sanitizeVariableName name}";
  in ''
    server {
        listen ${toString proxy.listenPort}${listenProtocolSuffix};
        proxy_pass ${proxyPassTarget};
    }
  '';

  streamListenKey = proxy: "${proxy.protocol}-${toString proxy.listenPort}";

  streamListenVariableName = key: "$stream_upstream_${sanitizeVariableName key}";

  groupStreamProxiesByListen = streamProxies:
    builtins.foldl'
    (
      acc: name: let
        proxy = streamProxies.${name};
        key = streamListenKey proxy;
        entry = proxy // {name = name;};
      in
        acc
        // {
          ${key} = (acc.${key} or []) ++ [entry];
        }
    )
    {}
    (builtins.attrNames streamProxies);

  mkNamedStreamProxyServer = listenKey: proxies: let
    firstProxy = builtins.head proxies;
    listenProtocolSuffix =
      if firstProxy.protocol == "udp"
      then " udp"
      else "";
    namedProxies = builtins.filter (proxy: proxy.serverNames != []) proxies;
    defaultProxy =
      builtins.head
      ((builtins.filter (proxy: proxy.serverNames == []) proxies) ++ [firstProxy]);
    upstreamName = proxy: "stream_${sanitizeVariableName proxy.name}";
    mapEntries =
      lib.concatMapStringsSep "\n"
      (proxy:
        lib.concatMapStringsSep "\n"
        (serverName: "    ${serverName} ${upstreamName proxy};")
        proxy.serverNames)
      namedProxies;
    mapBlock = ''
      map $ssl_preread_server_name ${streamListenVariableName listenKey} {
      ${mapEntries}
          default ${upstreamName defaultProxy};
      }
    '';
  in
    if firstProxy.protocol == "udp"
    then throw "nginx stream listener ${listenKey} cannot use nginxHostNames because UDP has no TLS SNI preread"
    else ''
      ${mapBlock}
      server {
          listen ${toString firstProxy.listenPort}${listenProtocolSuffix};
          proxy_pass ${streamListenVariableName listenKey};
          ssl_preread on;
      }
    '';

  mkStreamProxyListenServer = listenKey: proxies:
    if builtins.any (proxy: proxy.serverNames != []) proxies
    then mkNamedStreamProxyServer listenKey proxies
    else if builtins.length proxies == 1
    then mkStreamProxyServer (builtins.head proxies).name (builtins.head proxies)
    else throw "nginx stream listener ${listenKey} has multiple unnamed upstreams; set nginxHostNames for SNI routing or use distinct ports";

  renderStreamProxies = streamProxies: let
    upstreamBlocks =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (name: proxy:
          mkStreamUpstreamBlock "stream_${sanitizeVariableName name}" proxy.upstreams)
        streamProxies);
    servers =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList mkStreamProxyListenServer (groupStreamProxiesByListen streamProxies));
  in
    lib.concatStringsSep "\n" (builtins.filter (value: value != "") [
      upstreamBlocks
      servers
    ]);

  streamProxyFromExposedPort = name: portCfg: let
    protocols = portCfg.protocols or ["tcp"];
    upstreamProtocol = portCfg.upstreamProtocol or "http";
    upstreams =
      if (portCfg.upstreams or null) != null
      then portCfg.upstreams
      else ["localhost:${toString portCfg.port}"];
  in
    if builtins.length protocols != 1
    then throw "nginx stream proxy exposed port ${name} must declare exactly one protocol"
    else if builtins.head protocols != upstreamProtocol
    then throw "nginx stream proxy exposed port ${name} has protocols = [\"${builtins.head protocols}\"] but upstreamProtocol = \"${upstreamProtocol}\""
    else {
      listenPort = portCfg.port;
      protocol = upstreamProtocol;
      upstreams = upstreams;
      serverNames = portCfg.nginxHostNames or [];
    };

  streamProxiesFromExposedPorts = exposedPorts:
    lib.mapAttrs
    streamProxyFromExposedPort
    (lib.filterAttrs (_: portCfg: isStreamProtocol (portCfg.upstreamProtocol or "http")) exposedPorts);

  renderStreamProxiesFromExposedPorts = exposedPorts:
    renderStreamProxies (streamProxiesFromExposedPorts exposedPorts);

  streamPortMappings = streamProxies:
    lib.concatMap
    (protocol:
      map
      (port:
        if protocol == "udp"
        then "${toString port}:${toString port}/udp"
        else "${toString port}:${toString port}")
      (streamProxyPortsForProtocol protocol streamProxies))
    [
      "tcp"
      "udp"
    ];

  streamProxyPortsForProtocol = protocol: streamProxies:
    lib.unique (
      map
      (proxy: proxy.listenPort)
      (builtins.filter (proxy: proxy.protocol == protocol) (builtins.attrValues streamProxies))
    );

  streamProxyDnatInputRules = streamProxies:
    lib.concatStringsSep "\n"
    (lib.concatMap
      (protocol: let
        ports = streamProxyPortsForProtocol protocol streamProxies;
      in
        lib.optional (ports != [])
        "ct status dnat ${protocol} dport { ${lib.concatMapStringsSep ", " toString ports} } accept")
      [
        "tcp"
        "udp"
      ]);

  streamPortMappingsFromExposedPorts = exposedPorts:
    streamPortMappings (streamProxiesFromExposedPorts exposedPorts);

  streamProxyDnatInputRulesFromExposedPorts = exposedPorts:
    streamProxyDnatInputRules (streamProxiesFromExposedPorts exposedPorts);

  rateLimitZoneName = name: "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit";
  rateLimitMinuteZoneName = name: "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_minute";
  rateLimitQuarterHourZoneName = name: "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_quarter_hour";
  rateLimitHourZoneName = name: "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_hour";
  rateLimitBypassCidrsVarName = name: "$" + "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_bypass_cidrs";
  rateLimitTrustedProxyVarName = name: "$" + "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_trusted_proxy";
  rateLimitBypassTunnelVarName = name: "$" + "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_bypass_tunnel";
  rateLimitBypassVarName = name: "$" + "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_bypass";
  rateLimitKeyVarName = name: "$" + "proxy_${builtins.replaceStrings ["-"] ["_"] name}_rate_limit_key";
  lanBypassCidrs = [
    "127.0.0.0/8"
    "::1/128"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "fc00::/7"
    "fe80::/10"
  ];

  effectiveBypassCidrs = rateLimit:
    lib.unique (rateLimit.bypass.cidrs ++ lib.optionals rateLimit.bypass.lan lanBypassCidrs);

  mkRateLimitBypassGeo = name: rateLimit:
    lib.concatStrings
    ([
        "geo ${rateLimitBypassCidrsVarName name} {\n"
        "    default 0;\n"
      ]
      ++ map (cidr: "    ${cidr} 1;\n") (effectiveBypassCidrs rateLimit)
      ++ ["}\n"]);

  mkRateLimitTunnelBypassMap = name: ''
    geo $realip_remote_addr ${rateLimitTrustedProxyVarName name} {
        default 0;
        127.0.0.1/32 1;
        ::1/128 1;
        10.0.0.0/8 1;
        172.16.0.0/12 1;
        192.168.0.0/16 1;
        fc00::/7 1;
        fe80::/10 1;
    }

    map "$http_cf_connecting_ip:${rateLimitTrustedProxyVarName name}" ${rateLimitBypassTunnelVarName name} {
        default 0;
        ~^.+:1$ 1;
    }
  '';

  mkRateLimitBypassMap = name: ''
    map "${rateLimitBypassCidrsVarName name}:${rateLimitBypassTunnelVarName name}" ${rateLimitBypassVarName name} {
        default 0;
        1:0 1;
        0:1 1;
        1:1 1;
    }
  '';

  mkRateLimitKeyMap = name: ''
    map ${rateLimitBypassVarName name} ${rateLimitKeyVarName name} {
        1 "";
        0 $binary_remote_addr;
    }
  '';

  mkRateLimitZone = name: rateLimit:
    lib.concatStrings
    [
      (lib.optionalString
        (effectiveBypassCidrs rateLimit != [])
        (mkRateLimitBypassGeo name rateLimit))
      (lib.optionalString
        rateLimit.bypass.cloudflareTunnel
        (mkRateLimitTunnelBypassMap name))
      (lib.optionalString
        ((effectiveBypassCidrs rateLimit != []) || rateLimit.bypass.cloudflareTunnel)
        (mkRateLimitBypassMap name))
      (lib.optionalString
        ((effectiveBypassCidrs rateLimit != []) || rateLimit.bypass.cloudflareTunnel)
        (mkRateLimitKeyMap name))
      (lib.optionalString
        (rateLimit.requestsPerSecond != null)
        "limit_req_zone ${
          if (effectiveBypassCidrs rateLimit != []) || rateLimit.bypass.cloudflareTunnel
          then rateLimitKeyVarName name
          else "$binary_remote_addr"
        } zone=${rateLimitZoneName name}:10m rate=${toString rateLimit.requestsPerSecond}r/s;\n\n")
      (lib.optionalString
        (rateLimit.requestsPerMinute != null)
        "limit_req_zone ${
          if (effectiveBypassCidrs rateLimit != []) || rateLimit.bypass.cloudflareTunnel
          then rateLimitKeyVarName name
          else "$binary_remote_addr"
        } zone=${rateLimitMinuteZoneName name}:10m rate=${toString rateLimit.requestsPerMinute}r/m;\n\n")
      (lib.optionalString
        (rateLimit.requestsPerQuarterHour != null)
        "limit_req_zone ${
          if (effectiveBypassCidrs rateLimit != []) || rateLimit.bypass.cloudflareTunnel
          then rateLimitKeyVarName name
          else "$binary_remote_addr"
        } zone=${rateLimitQuarterHourZoneName name}:10m rate=${toString rateLimit.requestsPerQuarterHour}r/15m;\n\n")
      (lib.optionalString
        (rateLimit.requestsPerHour != null)
        "limit_req_zone ${
          if (effectiveBypassCidrs rateLimit != []) || rateLimit.bypass.cloudflareTunnel
          then rateLimitKeyVarName name
          else "$binary_remote_addr"
        } zone=${rateLimitHourZoneName name}:10m rate=${toString rateLimit.requestsPerHour}r/h;\n\n")
    ];

  mkRateLimitDirectives = name: rateLimit:
    lib.concatStrings
    [
      (lib.optionalString
        (rateLimit.requestsPerSecond != null)
        "    limit_req zone=${rateLimitZoneName name} burst=${toString rateLimit.requestsPerSecondBurst} nodelay;\n")
      (lib.optionalString
        (rateLimit.requestsPerMinute != null)
        "    limit_req zone=${rateLimitMinuteZoneName name} burst=${toString rateLimit.requestsPerMinuteBurst} nodelay;\n")
      (lib.optionalString
        (rateLimit.requestsPerQuarterHour != null)
        "    limit_req zone=${rateLimitQuarterHourZoneName name} burst=${toString rateLimit.requestsPerQuarterHourBurst} nodelay;\n")
      (lib.optionalString
        (rateLimit.requestsPerHour != null)
        "    limit_req zone=${rateLimitHourZoneName name} burst=${toString rateLimit.requestsPerHourBurst} nodelay;\n")
      "    limit_req_status ${toString rateLimit.statusCode};\n"
    ];

  authPrefix = auth: normalizeRoutePath (auth.prefix or "/oauth2");

  mkOauth2ProxyAuthLocations = auth: let
    prefix = authPrefix auth;
    requestScheme = auth.externalScheme or "$scheme";
    upstream = validatePlainUpstreamValue "authRequest.upstream" auth.upstream;
    dynamicUpstream = (auth.resolver or null) != null;
    clientBodyDirectives =
      lib.optionalString ((auth.clientMaxBodySize or null) != null)
      "        client_max_body_size ${auth.clientMaxBodySize};\n";
    resolverDirective = lib.optionalString dynamicUpstream ''
      resolver ${auth.resolver};
      set $auth_request_upstream ${upstream};
    '';
    proxyPassTarget =
      if dynamicUpstream
      then "$auth_request_upstream"
      else upstream;
  in ''
        location ${prefix}/ {
    ${resolverDirective}        proxy_pass http://${proxyPassTarget};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Scheme ${requestScheme};
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Proto ${requestScheme};
            proxy_set_header X-Forwarded-Uri $request_uri;
            proxy_set_header X-Auth-Request-Redirect ${requestScheme}://$host$request_uri;
        }

        location = ${prefix}/auth {
            internal;
    ${clientBodyDirectives}
    ${resolverDirective}        proxy_pass http://${proxyPassTarget};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Proto ${requestScheme};
            proxy_set_header X-Forwarded-Uri $request_uri;
            proxy_set_header Content-Length "";
            proxy_pass_request_body off;
        }

  '';

  mkAuthRequestDirectives = auth:
    if auth == null
    then ""
    else let
      prefix = authPrefix auth;
      requestScheme = auth.externalScheme or "$scheme";
      authHeaderDirectives = lib.optionalString (auth.passHeaders or true) ''
        auth_request_set $auth_request_user $upstream_http_x_auth_request_user;
        auth_request_set $auth_request_email $upstream_http_x_auth_request_email;
        auth_request_set $auth_request_groups $upstream_http_x_auth_request_groups;
        auth_request_set $auth_request_preferred_username $upstream_http_x_auth_request_preferred_username;
        proxy_set_header X-Auth-Request-User $auth_request_user;
        proxy_set_header X-Auth-Request-Email $auth_request_email;
        proxy_set_header X-Auth-Request-Groups $auth_request_groups;
        proxy_set_header X-Auth-Request-Preferred-Username $auth_request_preferred_username;
        proxy_set_header X-Forwarded-User $auth_request_user;
        proxy_set_header X-Forwarded-Email $auth_request_email;
        proxy_set_header X-Forwarded-Groups $auth_request_groups;
      '';
    in ''
                auth_request ${prefix}/auth;
                error_page 401 = ${prefix}/sign_in?rd=${requestScheme}://$host$request_uri;
                auth_request_set $auth_request_cookie $upstream_http_set_cookie;
                add_header Set-Cookie $auth_request_cookie always;
      ${authHeaderDirectives}
    '';

  locationRateLimitDirectives = name: rateLimit:
    lib.concatStrings
    (map
      (line: "        ${line}\n")
      (lib.filter (line: line != "") (lib.splitString "\n" (mkRateLimitDirectives name rateLimit))));

  renderRateLimitZones = vhosts:
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList
      (name: vhost:
        if vhost.rateLimit != null
        then mkRateLimitZone name vhost.rateLimit
        else "")
      vhosts);

  locationProxyPassDirectives = name: route: let
    routeRateLimit = route.rateLimit or null;
    routeUpstreamHost = route.upstreamHost or null;
    routeUpstreamProtocol = route.upstreamProtocol or "http";
    routeUpstreamTlsName = route.upstreamTlsName or "auto";
    routeUpstreamCaCertificate = route.upstreamCaCertificate or null;
    routeResolver = route.resolver or null;
    dynamicUpstream = routeResolver != null;
    dynamicUpstreamValue =
      if dynamicUpstream
      then
        if builtins.length route.upstreams != 1
        then throw "nginx route ${name} with resolver must define exactly one upstream"
        else validatePlainUpstreamValue "nginx route dynamic upstream" (builtins.head route.upstreams)
      else null;
    dynamicUpstreamVariable = "$route_upstream_${sanitizeVariableName name}";
    resolverDirective = lib.optionalString dynamicUpstream ''
      resolver ${routeResolver};
      set ${dynamicUpstreamVariable} ${dynamicUpstreamValue};
    '';
    proxyPassTarget =
      if dynamicUpstream
      then dynamicUpstreamVariable
      else name;
    routePrependPath = route.prependPath or null;
    routeStripPath = route.stripPath or false;
    rateLimitEnabled = routeRateLimit != null && routeRateLimit.enable;
    rateLimitDirectives =
      lib.optionalString rateLimitEnabled (locationRateLimitDirectives name routeRateLimit);
    securityHeaderDirectives = mkLocationSecurityHeaderIncludes route;
    authRequestDirectives = mkAuthRequestDirectives (route.authRequest or null);
    proxyBufferSize = route.proxyBufferSize or null;
    proxyBuffering = route.proxyBuffering or null;
    proxyBufferDirectives =
      lib.optionalString (proxyBufferSize != null)
      "        proxy_buffer_size ${proxyBufferSize};\n"
      + lib.optionalString (proxyBuffering != null)
      "        proxy_buffering ${
        if proxyBuffering
        then "on"
        else "off"
      };\n";
    proxyReadTimeout = route.proxyReadTimeout or null;
    proxySendTimeout = route.proxySendTimeout or null;
    proxyRequestBuffering = route.proxyRequestBuffering or null;
    proxyTimeoutDirectives =
      lib.optionalString (proxyReadTimeout != null)
      "        proxy_read_timeout ${proxyReadTimeout};\n"
      + lib.optionalString (proxySendTimeout != null)
      "        proxy_send_timeout ${proxySendTimeout};\n";
    proxyRequestBufferingDirective =
      lib.optionalString (proxyRequestBuffering != null)
      "        proxy_request_buffering ${
        if proxyRequestBuffering
        then "on"
        else "off"
      };\n";
    clientMaxBodySize = route.clientMaxBodySize or null;
    clientBodyDirectives =
      lib.optionalString (clientMaxBodySize != null)
      "        client_max_body_size ${clientMaxBodySize};\n";
    basePath = normalizeRoutePath route.path;
    prefixPath =
      if basePath == "/"
      then "/"
      else "${basePath}/";
    proxyCookiePath = route.proxyCookiePath or null;
    effectiveProxyCookiePath =
      if proxyCookiePath == null
      then prefixPath
      else proxyCookiePath;
    redirectTarget =
      if basePath == "/"
      then "$1"
      else "${basePath}$1";
    normalizedUpstreamHost =
      if routeUpstreamHost != null
      then validatePlainUpstreamValue "upstreamHost" routeUpstreamHost
      else null;
    effectiveUpstreamTlsName = resolveUpstreamTlsName {
      upstreamProtocol = routeUpstreamProtocol;
      upstreamHost = normalizedUpstreamHost;
      upstreamTlsName = routeUpstreamTlsName;
    };
    effectiveUpstreamPathPrefix =
      normalizeUpstreamPathPrefix
      routePrependPath;
    prefixedBasePath =
      if effectiveUpstreamPathPrefix == null
      then basePath
      else if basePath == "/"
      then effectiveUpstreamPathPrefix
      else "${effectiveUpstreamPathPrefix}${basePath}";
    prependRedirectDirective =
      lib.optionalString (effectiveUpstreamPathPrefix != null)
      "            proxy_redirect ~^${routeRegexEscape effectiveUpstreamPathPrefix}(/.*)?$ ${redirectTarget};\n";
    defaultRedirectDirective = "            proxy_redirect ~^(/.*)$ ${redirectTarget};\n";
    proxyRedirectDirectives = lib.concatMapStringsSep "" (redirect: ''
      proxy_redirect ${redirect.from} ${redirect.to};
    '') (route.proxyRedirects or []);
    exactRewriteDirective =
      if basePath != "/" && !routeStripPath && effectiveUpstreamPathPrefix != null
      then "        rewrite ^${routeRegexEscape basePath}$ ${prefixedBasePath} break;\n"
      else "";
    rewriteDirective =
      if basePath == "/"
      then lib.optionalString (effectiveUpstreamPathPrefix != null) "        rewrite ^/(.*)$ ${effectiveUpstreamPathPrefix}/$1 break;\n"
      else if routeStripPath
      then "        rewrite ^${routeRegexEscape prefixPath}(.*)$ ${
        if effectiveUpstreamPathPrefix == null
        then ""
        else effectiveUpstreamPathPrefix
      }/$1 break;\n"
      else lib.optionalString (effectiveUpstreamPathPrefix != null) "        rewrite ^${routeRegexEscape prefixPath}(.*)$ ${prefixedBasePath}/$1 break;\n";
    hostHeaderDirective =
      if normalizedUpstreamHost != null
      then "proxy_set_header Host ${normalizedUpstreamHost};"
      else "proxy_set_header Host $host;";
    forwardedHeaderDirectives = ''
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header X-Forwarded-Host $forwarded_host_effective;
      proxy_set_header X-Forwarded-Proto $forwarded_proto_effective;
      proxy_set_header X-Forwarded-Port $forwarded_port_effective;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header CF-Connecting-IP $remote_addr;
    '';
    upstreamTlsDirectives = lib.optionalString (effectiveUpstreamTlsName != null) ''
      proxy_ssl_server_name on;
      proxy_ssl_name ${effectiveUpstreamTlsName};
    '';
    upstreamTlsVerifyDirectives = lib.optionalString (routeUpstreamProtocol == "https" && routeUpstreamCaCertificate != null) ''
      proxy_ssl_verify on;
      proxy_ssl_verify_depth 3;
      proxy_ssl_trusted_certificate ${routeUpstreamCaCertificate};
    '';
    htmlRewriteDirectives =
      lib.optionalString (basePath != "/") (routeHtmlRewriteDirectives route effectiveUpstreamPathPrefix);
    forwardedPrefixDirective =
      lib.optionalString (basePath != "/")
      "            proxy_set_header X-Forwarded-Prefix ${prefixPath};\n";
  in ''
      ${rateLimitDirectives}${securityHeaderDirectives}${proxyBufferDirectives}${proxyTimeoutDirectives}${proxyRequestBufferingDirective}${clientBodyDirectives}${authRequestDirectives}        proxy_set_header Accept-Encoding "";
                ${hostHeaderDirective}
                ${forwardedHeaderDirectives}
    ${upstreamTlsDirectives}${upstreamTlsVerifyDirectives}            proxy_http_version 1.1;
                proxy_cookie_path / ${effectiveProxyCookiePath};
    ${proxyRedirectDirectives}${prependRedirectDirective}${defaultRedirectDirective}${forwardedPrefixDirective}
                ${htmlRewriteDirectives}
    ${resolverDirective}${exactRewriteDirective}${rewriteDirective}        proxy_pass ${routeUpstreamProtocol}://${proxyPassTarget};
  '';

  mkProxyRootLocation = name: proxy: let
    rootRoute =
      {
        path = "/";
        stripPath = false;
        upstreamProtocol = proxy.upstreamProtocol or "http";
        upstreamHost = proxy.upstreamHost or null;
        upstreamTlsName = proxy.upstreamTlsName or "auto";
        upstreamCaCertificate = proxy.upstreamCaCertificate or null;
        prependPath = proxy.prependPath or null;
        rateLimit = proxy.rateLimit or null;
        proxyBufferSize = proxy.proxyBufferSize or null;
        proxyBuffering = proxy.proxyBuffering or null;
        proxyReadTimeout = proxy.proxyReadTimeout or null;
        proxySendTimeout = proxy.proxySendTimeout or null;
        clientMaxBodySize = proxy.clientMaxBodySize or null;
        proxyCookiePath = proxy.proxyCookiePath or null;
        proxyRedirects = proxy.proxyRedirects or [];
        authRequest = proxy.authRequest or null;
      }
      // upstreamHeaderFlags proxy;
    rootRedirect = proxy.rootRedirect or null;
    rootRedirectBlock = lib.optionalString (rootRedirect != null) ''
      location = / {
          return ${toString rootRedirect.status} ${rootRedirect.path}$is_args$args;
      }

    '';
  in ''
    ${rootRedirectBlock}
            location / {
    ${locationProxyPassDirectives name rootRoute}        }
  '';

  routeRegexEscape = value:
    builtins.replaceStrings
    [
      "\\"
      "."
      "+"
      "*"
      "?"
      "^"
      "$"
      "("
      ")"
      "["
      "]"
      "{"
      "}"
      "|"
    ]
    [
      "\\\\"
      "\\."
      "\\+"
      "\\*"
      "\\?"
      "\\^"
      "\\$"
      "\\("
      "\\)"
      "\\["
      "\\]"
      "\\{"
      "\\}"
      "\\|"
    ]
    value;

  routePrefixPath = route: let
    normalizedPath = normalizeRoutePath route.path;
  in
    if normalizedPath == "/"
    then "/"
    else "${normalizedPath}/";

  routeHtmlRewriteDirectives = route: prependPathPrefix: let
    prefixPath = routePrefixPath route;
    prependRewriteDirectives = lib.optionalString (prependPathPrefix != null) ''
      sub_filter 'href="${prependPathPrefix}/' 'href="${prefixPath}';
      sub_filter 'src="${prependPathPrefix}/' 'src="${prefixPath}';
      sub_filter 'action="${prependPathPrefix}/' 'action="${prefixPath}';
      sub_filter 'content="${prependPathPrefix}/' 'content="${prefixPath}';
      sub_filter 'url(${prependPathPrefix}/' 'url(${prefixPath}';
    '';
  in ''
    sub_filter_once off;
    sub_filter_types text/html;
    ${prependRewriteDirectives}sub_filter 'href="/' 'href="${prefixPath}';
    sub_filter 'src="/' 'src="${prefixPath}';
    sub_filter 'action="/' 'action="${prefixPath}';
    sub_filter 'content="/' 'content="${prefixPath}';
    sub_filter 'url(/' 'url(${prefixPath}';
  '';

  mkProxyRouteLocation = name: route: let
    basePath = normalizeRoutePath route.path;
    explicitLocation = route.location or null;
    routeStripPath = route.stripPath or false;
    prefixPath =
      if basePath == "/"
      then "/"
      else "${basePath}/";
    exactLocation =
      if basePath == "/"
      then ""
      else if routeStripPath
      then ''
        location = ${basePath} {
            return 307 ${prefixPath}$is_args$args;
        }
      ''
      else ''
                    location = ${basePath} {
        ${locationProxyPassDirectives name route}            }
      '';
    prefixLocation =
      if basePath == "/"
      then ''
                    location / {
        ${locationProxyPassDirectives name route}            }
      ''
      else ''
                    location ^~ ${prefixPath} {
        ${locationProxyPassDirectives name route}            }
      '';
  in
    if explicitLocation != null
    then ''
                  location ${explicitLocation} {
      ${locationProxyPassDirectives name route}          }
    ''
    else exactLocation + prefixLocation;

  staticSiteLocation = name: site: rateLimit: let
    rateLimitDirectives =
      lib.optionalString (rateLimit != null) (locationRateLimitDirectives name rateLimit);
    staticAssetLocation = lib.optionalString site.singlePageApp ''
            location ~ \.[^/]+$ {
      ${rateLimitDirectives}                try_files $uri =404;
            }
    '';
  in
    staticAssetLocation
    + (
      if site.singlePageApp
      then ''
              location / {
        ${rateLimitDirectives}                try_files $uri $uri/ /${site.index};
              }
      ''
      else ''
              location / {
        ${rateLimitDirectives}                try_files $uri $uri/ =404;
              }
      ''
    );

  staticSiteMountPath = name: site:
    if site.mountPath != null
    then site.mountPath
    else "/srv/${name}";

  staticRouteName = siteName: route: "${siteName}-${sanitizeName route.serverName}-${sanitizeName route.path}";

  staticRoutesFromSites = staticSites:
    lib.concatMapAttrs
    (siteName: site:
      lib.listToAttrs
      (map
        (route: let
          normalizedPath = normalizeRoutePath route.path;
          routeName = staticRouteName siteName route;
        in
          assert lib.hasPrefix "/" normalizedPath;
          assert normalizedPath != "/"; {
            name = routeName;
            value = {
              service = null;
              mode = "static";
              serverName = route.serverName;
              path = normalizedPath;
              siteMountPath = staticSiteMountPath siteName site;
              siteIndex = site.index;
              siteSinglePageApp = site.singlePageApp;
              rateLimit = null;
            };
          })
        site.routes))
    staticSites;

  resolveRateLimit = rateLimit:
    exposedPortsLib.resolveRateLimit {
      defaultRateLimit = rateLimitProfiles.default;
      rateLimit = rateLimit;
    };

  routeTryFilesTarget = route:
    if route.siteSinglePageApp
    then "${route.path}/${route.siteIndex}"
    else "=404";

  mkStaticRouteLocation = name: route: let
    basePath = normalizeRoutePath route.path;
    rateLimitEnabled = route.rateLimit != null && route.rateLimit.enable;
    rateLimitDirectives =
      lib.optionalString rateLimitEnabled (locationRateLimitDirectives name route.rateLimit);
    prefixPath = "${basePath}/";
  in ''
        location = ${basePath} {
            return 307 ${prefixPath}$is_args$args;
        }

        location ^~ ${prefixPath} {
    ${rateLimitDirectives}        alias ${route.siteMountPath}/;
            index ${route.siteIndex};
            ${routeHtmlRewriteDirectives route null}
            try_files $uri $uri/ ${routeTryFilesTarget route};
        }
  '';

  routesForServer = serverName: routes:
    lib.filterAttrs (_: route: route.serverName == serverName) routes;

  defaultServerBlock = ''
    location / {
        return 404;
    }
  '';

  proxyRootsByServerName = proxyVhosts:
    lib.concatMapAttrs
    (proxyName: proxy:
      lib.listToAttrs
      (map
        (serverName: {
          name = serverName;
          value = proxy // {name = proxyName;};
        })
        proxy.serverNames))
    proxyVhosts;

  staticRootsByServerName = staticSites:
    lib.concatMapAttrs
    (siteName: site:
      lib.listToAttrs
      (map
        (serverName: {
          name = serverName;
          value = site // {name = siteName;};
        })
        site.serverNames))
    staticSites;

  redirectRootsByServerName = redirectVhosts:
    lib.concatMapAttrs
    (redirectName: redirect:
      lib.listToAttrs
      (map
        (serverName: {
          name = serverName;
          value = redirect // {name = redirectName;};
        })
        redirect.serverNames))
    redirectVhosts;

  rootHostnames = {
    redirectVhosts,
    staticSites,
    proxyVhosts,
  }:
    (lib.flatten
      (lib.mapAttrsToList
        (_: redirect: redirect.serverNames)
        redirectVhosts))
    ++ (lib.flatten
      (lib.mapAttrsToList
        (_: site: site.serverNames)
        staticSites))
    ++ (lib.flatten
      (lib.mapAttrsToList
        (_: proxy: proxy.serverNames)
        proxyVhosts));

  duplicateRootHostnames = serverNames:
    builtins.attrNames
    (lib.filterAttrs
      (_: count: count > 1)
      (lib.foldl'
        (acc: serverName:
          acc
          // {
            ${serverName} = (acc.${serverName} or 0) + 1;
          })
        {}
        serverNames));

  mkMergedServer = {
    serverName,
    rootRedirectVhost ? null,
    rootStaticSite ? null,
    rootProxy ? null,
    routes ? {},
    staticRateLimit,
    listenDirectives,
    serverExtraDirectives,
  }: let
    authRequests =
      lib.unique
      (lib.filter
        (auth: auth != null)
        ((lib.optional (rootProxy != null) (rootProxy.authRequest or null))
          ++ map (route: route.authRequest or null) (builtins.attrValues routes)));
    authLocationBlocks =
      lib.concatStringsSep "\n"
      (map
        (auth:
          if (auth.provider or "oauth2-proxy") == "oauth2-proxy"
          then mkOauth2ProxyAuthLocations auth
          else throw "Unsupported auth_request provider: ${auth.provider}")
        authRequests);
    routeBlocks =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (name: route:
          if route.mode == "static"
          then mkStaticRouteLocation name route
          else mkProxyRouteLocation name route)
        routes);
    rootBlock =
      if rootRedirectVhost != null
      then ''
        location / {
            return ${toString (rootRedirectVhost.status or 307)} ${rootRedirectVhost.target}${lib.optionalString (rootRedirectVhost.preserveQuery or true) "$is_args$args"};
        }
      ''
      else if rootStaticSite != null
      then let
        mountPath = staticSiteMountPath rootStaticSite.name rootStaticSite;
      in ''
        root ${mountPath};
        index ${rootStaticSite.index};

        ${staticSiteLocation rootStaticSite.name rootStaticSite staticRateLimit}
      ''
      else if rootProxy != null
      then mkProxyRootLocation rootProxy.name rootProxy
      else defaultServerBlock;
  in
    assert rootRedirectVhost != null || rootStaticSite != null || rootProxy != null || routes != {}; ''
            server {
      ${lib.concatMapStringsSep "\n" (directive: "        ${directive}") listenDirectives}
              server_name ${serverName};
      ${serverExtraDirectives}

              include /etc/nginx/conf.d/lib/http-security.conf;

      ${authLocationBlocks}
      ${lib.optionalString (routeBlocks != "") routeBlocks}
      ${rootBlock}
            }
    '';
in rec {
  inherit mkProxyTimeout mkProxyTimeouts rateLimitProfiles;
  proxyVhostType = proxyVhostTypeDef;
  redirectVhostType = redirectVhostTypeDef;
  routeType = routeTypeDef;

  composeSource = ./compose/compose.yaml;

  baseFiles = {
    "nginx.conf".source = ./compose/nginx.conf;
    "conf.d".source = ./compose/conf.d;
    "conf.d/metrics-status.conf".text = ''
      server {
          listen 80 default_server;
          server_name _;

          location = /nginx_status {
              stub_status;
              access_log off;
              allow 127.0.0.1;
              allow ::1;
              allow 10.0.0.0/8;
              allow 172.16.0.0/12;
              allow 192.168.0.0/16;
              deny all;
          }

          location / {
              return 404;
          }
      }
    '';
  };

  proxyVhostsFromInstances = {defaultHost ? "localhost"}: instances:
    lib.concatMapAttrs
    (serviceName: service:
      lib.concatMapAttrs
      (
        portName: portCfg:
          mkProxyVhost {
            defaultHost = defaultHost;
          }
          serviceName
          portName
          portCfg
      )
      service.exposedPorts)
    instances;

  routesFromInstances = {defaultHost ? "localhost"}: instances:
    lib.concatMapAttrs
    (serviceName: service:
      lib.concatMapAttrs
      (
        portName: portCfg:
          mkDynamicRoutes {
            defaultHost = defaultHost;
          }
          serviceName
          portName
          portCfg
      )
      service.exposedPorts)
    instances;

  dependencyServices = proxyVhosts:
    lib.unique (lib.filter (s: s != null) (map (proxy: proxy.service) (builtins.attrValues proxyVhosts)));

  renderProxyServers = proxyVhosts:
    renderServers {
      inherit proxyVhosts;
    };

  mkStaticSite = {
    serverNames ? [],
    rootPath,
    mountPath ? null,
    index ? "index.html",
    singlePageApp ? false,
    routes ? [],
  }: {
    inherit serverNames rootPath mountPath index singlePageApp routes;
  };

  renderStaticServers = {
    rateLimit ? null,
    nginxRoutes ? {},
  }: staticSites:
    renderServers {
      inherit rateLimit nginxRoutes staticSites;
      proxyVhosts = {};
    };

  renderServers = {
    rateLimit ? null,
    nginxRoutes ? {},
    proxyVhosts ? {},
    redirectVhosts ? {},
    staticSites ? {},
    includeHttpPreamble ? true,
    listenDirectives ? ["listen 80;"],
    serverExtraDirectives ? "",
  }: let
    resolvedRateLimit = resolveRateLimit rateLimit;
    namedStaticSites =
      lib.mapAttrs
      (name: site: site // {name = name;})
      staticSites;
    rootRedirectVhostsByServerName = redirectRootsByServerName redirectVhosts;
    staticRoutes =
      lib.mapAttrs
      (_: route: route // {rateLimit = resolvedRateLimit;})
      (staticRoutesFromSites namedStaticSites);
    staticVhosts =
      lib.mapAttrs
      (_: _: {
        rateLimit = resolvedRateLimit;
      })
      (lib.filterAttrs (_: site: site.serverNames != []) namedStaticSites);
    rootProxyVhostsByServerName = proxyRootsByServerName proxyVhosts;
    rootStaticSitesByServerName = staticRootsByServerName namedStaticSites;
    duplicateHostnames = duplicateRootHostnames (rootHostnames {
      redirectVhosts = redirectVhosts;
      staticSites = namedStaticSites;
      proxyVhosts = proxyVhosts;
    });
    duplicateHostnamesError =
      "Duplicate nginx root hostnames are not supported: "
      + lib.concatStringsSep ", " duplicateHostnames;
    rateLimitZones =
      renderRateLimitZones (staticVhosts // staticRoutes // nginxRoutes // proxyVhosts);
    proxyUpstreamBlocks =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList (name: proxy: mkUpstreamBlock name proxy.upstreams) proxyVhosts);
    routeUpstreamBlocks =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (name: route:
          if route.mode == "upstream" && (route.resolver or null) == null
          then mkUpstreamBlock name route.upstreams
          else "")
        nginxRoutes);
    serverNames = lib.unique (
      builtins.attrNames rootRedirectVhostsByServerName
      ++ builtins.attrNames rootStaticSitesByServerName
      ++ builtins.attrNames rootProxyVhostsByServerName
      ++ map (route: route.serverName) (builtins.attrValues (staticRoutes // nginxRoutes))
    );
    servers =
      lib.concatStringsSep "\n"
      (map
        (serverName:
          assert !(builtins.hasAttr serverName rootRedirectVhostsByServerName && builtins.hasAttr serverName rootStaticSitesByServerName);
          assert !(builtins.hasAttr serverName rootRedirectVhostsByServerName && builtins.hasAttr serverName rootProxyVhostsByServerName);
          assert !(builtins.hasAttr serverName rootStaticSitesByServerName && builtins.hasAttr serverName rootProxyVhostsByServerName);
            mkMergedServer {
              inherit serverName;
              rootRedirectVhost = rootRedirectVhostsByServerName.${serverName} or null;
              rootStaticSite = rootStaticSitesByServerName.${serverName} or null;
              rootProxy = rootProxyVhostsByServerName.${serverName} or null;
              routes = routesForServer serverName (staticRoutes // nginxRoutes);
              staticRateLimit = resolvedRateLimit;
              inherit listenDirectives serverExtraDirectives;
            })
        serverNames);
  in
    if duplicateHostnames != []
    then throw duplicateHostnamesError
    else if includeHttpPreamble
    then
      lib.optionalString
      (rateLimitZones != "")
      "${rateLimitZones}\n${proxyUpstreamBlocks}\n${routeUpstreamBlocks}\n${servers}"
      + lib.optionalString
      (rateLimitZones == "")
      "${proxyUpstreamBlocks}\n${routeUpstreamBlocks}\n${servers}"
    else servers;

  staticSiteComposeOverride = staticSites:
    lib.generators.toYAML {} {
      services.nginx.volumes =
        map
        (name: let
          site = staticSites.${name};
        in "${toString site.rootPath}:${staticSiteMountPath name site}:ro")
        (builtins.attrNames staticSites);
    };

  nginxExporterPort = 9113;

  nginxExporterConfig = {
    httpPort,
    enable ? true,
    port ? nginxExporterPort,
  }: {
    inherit enable port;
    listenAddress = "127.0.0.1";
    scrapeUri = "http://127.0.0.1:${toString httpPort}/nginx_status";
  };

  inherit
    renderStreamProxiesFromExposedPorts
    renderStreamProxies
    streamPortMappingsFromExposedPorts
    streamPortMappings
    streamProxiesFromExposedPorts
    streamProxyDnatInputRulesFromExposedPorts
    streamProxyDnatInputRules
    streamProxyPortsForProtocol
    streamProxyTypeDef
    ;
}

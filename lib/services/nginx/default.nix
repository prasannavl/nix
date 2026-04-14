{lib}: let
  exposedPortsLib = import ../exposed-ports {inherit lib;};
  rateLimitProfiles = {
    default = exposedPortsLib.defaultRateLimitProfile;
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
        description = "Optional origin hostname for Host header and TLS SNI when proxying to this backend.";
      };

      prependPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional fixed path prefix to prepend when proxying to this backend.";
      };

      rateLimit = lib.mkOption {
        type = lib.types.nullOr exposedPortsLib.rateLimitProfileType;
        default = null;
        description = "Optional resolved ingress rate-limiting policy for this proxy vhost.";
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
        description = "Optional origin hostname for Host header and TLS SNI when proxying to this backend route.";
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
    };
  };

  mkProxyVhost = {defaultHost ? "localhost"}: serviceName: portName: portCfg: let
    nginxHostNames = portCfg.nginxHostNames or [];
  in
    lib.optionalAttrs (nginxHostNames != []) {
      "${serviceName}-${portName}" = {
        service = serviceName;
        inherit (portCfg) port;
        serverNames = nginxHostNames;
        upstreams = ["${defaultHost}:${toString portCfg.port}"];
        rateLimit = resolveRateLimit (portCfg.rateLimit or null);
      };
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
      in
        assert lib.hasPrefix "/" normalizedPath;
        assert normalizedPath != "/"; {
          name = routeName;
          value = {
            service = serviceName;
            mode = "upstream";
            serverName = route.serverName;
            path = normalizedPath;
            inherit (portCfg) port;
            upstreams = ["${defaultHost}:${toString portCfg.port}"];
            upstreamProtocol = "http";
            upstreamHost = null;
            prependPath = null;
            stripPath = route.stripPath;
            rateLimit = resolveRateLimit (portCfg.rateLimit or null);
          };
        })
      (portCfg.nginxRoutes or []));

  mkUpstreamBlock = name: upstreams:
    lib.concatStrings
    [
      "upstream ${name} {\n"
      "    ${lib.concatMapStringsSep "\n    " (s: "server ${validatePlainUpstreamValue "nginx upstream server" s};") upstreams}\n"
      "}\n"
    ];

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
    routePrependPath = route.prependPath or null;
    routeStripPath = route.stripPath or false;
    rateLimitEnabled = routeRateLimit != null && routeRateLimit.enable;
    rateLimitDirectives =
      lib.optionalString rateLimitEnabled (locationRateLimitDirectives name routeRateLimit);
    basePath = normalizeRoutePath route.path;
    prefixPath =
      if basePath == "/"
      then "/"
      else "${basePath}/";
    redirectTarget =
      if basePath == "/"
      then "/$1"
      else "${basePath}$1";
    normalizedUpstreamHost =
      if routeUpstreamHost != null
      then validatePlainUpstreamValue "upstreamHost" routeUpstreamHost
      else null;
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
    upstreamHostDirectives = lib.optionalString (normalizedUpstreamHost != null) ''
      proxy_set_header Host ${normalizedUpstreamHost};
    '';
    upstreamTlsDirectives =
      lib.optionalString (routeUpstreamProtocol == "https") ''
        proxy_ssl_server_name on;
      ''
      + lib.optionalString (normalizedUpstreamHost != null) ''
        proxy_ssl_name ${normalizedUpstreamHost};
      '';
    htmlRewriteDirectives =
      lib.optionalString (basePath != "/") (routeHtmlRewriteDirectives route effectiveUpstreamPathPrefix);
  in ''
        ${rateLimitDirectives}        proxy_set_header Accept-Encoding "";
    ${upstreamHostDirectives}${upstreamTlsDirectives}            proxy_http_version 1.1;
                proxy_cookie_path / ${prefixPath};
    ${prependRedirectDirective}${defaultRedirectDirective}            proxy_set_header X-Forwarded-Prefix ${prefixPath};
                ${htmlRewriteDirectives}
    ${exactRewriteDirective}${rewriteDirective}        proxy_pass ${routeUpstreamProtocol}://${name};
  '';

  mkProxyRootLocation = name: proxy: let
    rootRoute = {
      path = "/";
      stripPath = false;
      upstreamProtocol = proxy.upstreamProtocol or "http";
      upstreamHost = proxy.upstreamHost or null;
      prependPath = proxy.prependPath or null;
      rateLimit = proxy.rateLimit or null;
    };
  in ''
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
    prefixPath =
      if basePath == "/"
      then "/"
      else "${basePath}/";
    exactLocation =
      if basePath == "/"
      then ""
      else if route.stripPath
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
    exactLocation + prefixLocation;

  staticSiteLocation = name: site: rateLimit: let
    rateLimitDirectives =
      lib.optionalString (rateLimit != null) (locationRateLimitDirectives name rateLimit);
  in
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
    '';

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

  rootHostnames = {
    staticSites,
    proxyVhosts,
  }:
    (lib.flatten
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
    rootStaticSite ? null,
    rootProxy ? null,
    routes ? {},
    staticRateLimit,
  }: let
    routeBlocks =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (name: route:
          if route.mode == "static"
          then mkStaticRouteLocation name route
          else mkProxyRouteLocation name route)
        routes);
    rootBlock =
      if rootStaticSite != null
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
    assert rootStaticSite != null || rootProxy != null || routes != {}; ''
            server {
              listen 80;
              server_name ${serverName};

              include /etc/nginx/conf.d/lib/http-security.conf;

      ${lib.optionalString (routeBlocks != "") routeBlocks}
      ${rootBlock}
            }
    '';
in rec {
  inherit rateLimitProfiles;
  proxyVhostType = proxyVhostTypeDef;
  routeType = routeTypeDef;

  composeSource = ./compose/compose.yaml;

  baseFiles = {
    "nginx.conf" = ./compose/nginx.conf;
    "conf.d" = ./compose/conf.d;
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
    staticSites ? {},
  }: let
    resolvedRateLimit = resolveRateLimit rateLimit;
    namedStaticSites =
      lib.mapAttrs
      (name: site: site // {name = name;})
      staticSites;
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
          if route.mode == "upstream"
          then mkUpstreamBlock name route.upstreams
          else "")
        nginxRoutes);
    serverNames = lib.unique (
      builtins.attrNames rootStaticSitesByServerName
      ++ builtins.attrNames rootProxyVhostsByServerName
      ++ map (route: route.serverName) (builtins.attrValues (staticRoutes // nginxRoutes))
    );
    servers =
      lib.concatStringsSep "\n"
      (map
        (serverName:
          assert !(builtins.hasAttr serverName rootStaticSitesByServerName && builtins.hasAttr serverName rootProxyVhostsByServerName);
            mkMergedServer {
              inherit serverName;
              rootStaticSite = rootStaticSitesByServerName.${serverName} or null;
              rootProxy = rootProxyVhostsByServerName.${serverName} or null;
              routes = routesForServer serverName (staticRoutes // nginxRoutes);
              staticRateLimit = resolvedRateLimit;
            })
        serverNames);
  in
    if duplicateHostnames != []
    then throw duplicateHostnamesError
    else
      lib.optionalString
      (rateLimitZones != "")
      "${rateLimitZones}\n${proxyUpstreamBlocks}\n${routeUpstreamBlocks}\n${servers}"
      + lib.optionalString
      (rateLimitZones == "")
      "${proxyUpstreamBlocks}\n${routeUpstreamBlocks}\n${servers}";

  staticSiteComposeOverride = staticSites:
    lib.generators.toYAML {} {
      services.nginx.volumes =
        map
        (name: let
          site = staticSites.${name};
        in "${toString site.rootPath}:${staticSiteMountPath name site}:ro")
        (builtins.attrNames staticSites);
    };
}

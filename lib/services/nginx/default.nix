{lib}: let
  exposedPortsLib = import ../exposed-ports {inherit lib;};
  rateLimitProfiles = {
    default = exposedPortsLib.defaultRateLimitProfile;
  };
  proxyVhostType = lib.types.submodule {
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

      rateLimit = lib.mkOption {
        type = lib.types.nullOr exposedPortsLib.rateLimitProfileType;
        default = null;
        description = "Optional resolved ingress rate-limiting policy for this proxy vhost.";
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

  mkUpstreamBlock = name: upstreams:
    lib.concatStrings
    [
      "upstream ${name} {\n"
      "    ${lib.concatMapStringsSep "\n    " (s: "server ${s};") upstreams}\n"
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

  renderRateLimitZones = vhosts:
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList
      (name: vhost:
        if vhost.rateLimit != null
        then mkRateLimitZone name vhost.rateLimit
        else "")
      vhosts);

  mkProxyServer = name: proxy: let
    rateLimitEnabled = proxy.rateLimit != null && proxy.rateLimit.enable;
  in
    lib.concatStrings
    [
      (mkUpstreamBlock name proxy.upstreams)
      "\n"
      "# ${name}\n"
      "server {\n"
      "    listen 80;\n"
      "    server_name ${lib.concatStringsSep " " proxy.serverNames};\n\n"
      "    include /etc/nginx/conf.d/lib/http-security.conf;\n"
      (lib.optionalString rateLimitEnabled (mkRateLimitDirectives name proxy.rateLimit))
      "\n"
      "    location / {\n"
      "        proxy_pass http://${name};\n"
      "    }\n"
      "}\n"
    ];

  staticSiteLocation = site:
    if site.singlePageApp
    then "location / {\n            try_files $uri $uri/ /${site.index};\n        }"
    else "location / {\n            try_files $uri $uri/ =404;\n        }";

  staticSiteMountPath = name: site:
    if site.mountPath != null
    then site.mountPath
    else "/srv/${name}";

  resolveRateLimit = rateLimit:
    exposedPortsLib.resolveRateLimit {
      defaultRateLimit = rateLimitProfiles.default;
      rateLimit = rateLimit;
    };

  mkStaticServer = rateLimit: name: site: let
    mountPath = staticSiteMountPath name site;
  in ''
        server {
            listen 80;
            server_name ${lib.concatStringsSep " " site.serverNames};

            include /etc/nginx/conf.d/lib/http-security.conf;
    ${lib.optionalString (rateLimit != null) (mkRateLimitDirectives name rateLimit)}

            root ${mountPath};
            index ${site.index};

            ${staticSiteLocation site}
        }
  '';
in {
  inherit rateLimitProfiles;
  proxyVhostType = proxyVhostType;

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

  dependencyServices = proxyVhosts:
    lib.unique (lib.filter (s: s != null) (map (proxy: proxy.service) (builtins.attrValues proxyVhosts)));

  renderProxyServers = proxyVhosts: let
    rateLimitZones = renderRateLimitZones proxyVhosts;
    servers = lib.concatStringsSep "\n" (lib.mapAttrsToList mkProxyServer proxyVhosts);
  in
    lib.optionalString (rateLimitZones != "") "${rateLimitZones}\n${servers}"
    + lib.optionalString (rateLimitZones == "") servers;

  mkStaticSite = {
    serverNames,
    rootPath,
    mountPath ? null,
    index ? "index.html",
    singlePageApp ? false,
  }: {
    inherit serverNames rootPath mountPath index singlePageApp;
  };

  renderStaticServers = {rateLimit ? null}: staticSites: let
    resolvedRateLimit = resolveRateLimit rateLimit;
    staticVhosts =
      lib.mapAttrs
      (name: site: {
        rateLimit = resolvedRateLimit;
      })
      staticSites;
    rateLimitZones =
      if resolvedRateLimit == null
      then ""
      else renderRateLimitZones staticVhosts;
    servers =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList (mkStaticServer resolvedRateLimit) staticSites);
  in
    lib.optionalString (rateLimitZones != "") "${rateLimitZones}\n${servers}"
    + lib.optionalString (rateLimitZones == "") servers;

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

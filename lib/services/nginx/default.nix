{lib}: let
  defaultRateLimit = {
    enable = true;
    key = "$binary_remote_addr";
    zoneSize = "10m";
    rate = "10r/s";
    burst = 20;
    nodelay = true;
    statusCode = 429;
    dryRun = false;
  };

  rateLimitType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = defaultRateLimit.enable;
        description = "Whether nginx should apply request rate limiting to this proxy vhost.";
      };

      key = lib.mkOption {
        type = lib.types.str;
        default = defaultRateLimit.key;
        description = "Nginx variable used to key the rate-limit zone, for example $binary_remote_addr.";
      };

      zoneSize = lib.mkOption {
        type = lib.types.str;
        default = defaultRateLimit.zoneSize;
        description = "Shared-memory zone size for the nginx request rate limiter.";
      };

      rate = lib.mkOption {
        type = lib.types.str;
        default = defaultRateLimit.rate;
        description = "Nginx request rate such as 10r/s or 300r/m.";
      };

      burst = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = defaultRateLimit.burst;
        description = "Burst size nginx allows above the steady-state request rate.";
      };

      nodelay = lib.mkOption {
        type = lib.types.bool;
        default = defaultRateLimit.nodelay;
        description = "Whether burst requests should be served immediately instead of delayed.";
      };

      statusCode = lib.mkOption {
        type = lib.types.ints.between 400 599;
        default = defaultRateLimit.statusCode;
        description = "HTTP status code nginx returns when the request rate limit is exceeded.";
      };

      dryRun = lib.mkOption {
        type = lib.types.bool;
        default = defaultRateLimit.dryRun;
        description = "Whether nginx should evaluate the limit without enforcing it.";
      };
    };
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
        type = lib.types.nullOr rateLimitType;
        default = defaultRateLimit;
        description = "Optional nginx request rate-limiting policy for this proxy vhost. Set to null to disable.";
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
        rateLimit = portCfg.rateLimit;
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

  mkRateLimitZone = name: rateLimit: "limit_req_zone ${rateLimit.key} zone=${rateLimitZoneName name}:${rateLimit.zoneSize} rate=${rateLimit.rate};\n";

  mkRateLimitDirectives = name: rateLimit:
    lib.concatStrings
    ([
        "    limit_req zone=${rateLimitZoneName name} burst=${toString rateLimit.burst}${lib.optionalString rateLimit.nodelay " nodelay"};\n"
        "    limit_req_status ${toString rateLimit.statusCode};\n"
      ]
      ++ lib.optional rateLimit.dryRun "    limit_req_dry_run on;\n");

  mkProxyServer = name: proxy: let
    rateLimitEnabled = proxy.rateLimit != null && proxy.rateLimit.enable;
  in
    lib.concatStrings
    [
      (mkUpstreamBlock name proxy.upstreams)
      "\n"
      (lib.optionalString rateLimitEnabled (mkRateLimitZone name proxy.rateLimit))
      (lib.optionalString rateLimitEnabled "\n")
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
    if site.spa
    then "location / {\n            try_files $uri $uri/ /${site.index};\n        }"
    else "location / {\n            try_files $uri $uri/ =404;\n        }";

  staticSiteMountPath = name: site:
    if site.mountPath != null
    then site.mountPath
    else "/srv/${name}";

  mkStaticServer = name: site: let
    mountPath = staticSiteMountPath name site;
  in ''
    server {
        listen 80;
        server_name ${lib.concatStringsSep " " site.serverNames};

        include /etc/nginx/conf.d/lib/http-security.conf;

        root ${mountPath};
        index ${site.index};

        ${staticSiteLocation site}
    }
  '';
in {
  defaultRateLimit = defaultRateLimit;
  rateLimitType = rateLimitType;
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
      (portName: portCfg: mkProxyVhost {inherit defaultHost;} serviceName portName portCfg)
      service.exposedPorts)
    instances;

  dependencyServices = proxyVhosts:
    lib.unique (lib.filter (s: s != null) (map (proxy: proxy.service) (builtins.attrValues proxyVhosts)));

  renderProxyServers = proxyVhosts:
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkProxyServer proxyVhosts);

  mkStaticSite = {
    serverNames,
    rootPath,
    mountPath ? null,
    index ? "index.html",
    spa ? false,
  }: {
    inherit serverNames rootPath mountPath index spa;
  };

  renderStaticServers = staticSites:
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkStaticServer staticSites);

  staticSiteFiles = staticSites:
    lib.concatMapAttrs (name: site: {"site/${name}" = site.rootPath;}) staticSites;

  staticSiteComposeOverride = staticSites:
    lib.generators.toYAML {} {
      services.nginx.volumes =
        map
        (name: let
          site = staticSites.${name};
        in "./site/${name}:${staticSiteMountPath name site}:ro")
        (builtins.attrNames staticSites);
    };
}

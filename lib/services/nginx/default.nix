{lib}: let
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
    };
  };

  staticSiteType = lib.types.submodule {
    options = {
      serverNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Hostname(s) served by this static site.";
      };

      rootPath = lib.mkOption {
        type = lib.types.path;
        description = "Directory path to mount into the nginx container.";
      };

      mountPath = lib.mkOption {
        type = lib.types.str;
        description = "Container path nginx should use as the document root.";
      };

      index = lib.mkOption {
        type = lib.types.str;
        default = "index.html";
        description = "Index file served by nginx for this site.";
      };

      spa = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether requests should fall back to /index.html.";
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
      };
    };

  mkUpstreamBlock = name: upstreams: ''
    upstream ${name} {
        ${lib.concatMapStringsSep "\n        " (s: "server ${s};") upstreams}
    }
  '';

  mkProxyServer = name: proxy: ''
    ${mkUpstreamBlock name proxy.upstreams}
    # ${name}
    server {
        listen 80;
        server_name ${lib.concatStringsSep " " proxy.serverNames};

        include /etc/nginx/conf.d/lib/http-security.conf;

        location / {
            proxy_pass http://${name};
        }
    }
  '';

  staticSiteLocation = site:
    if site.spa
    then "location / {\n            try_files $uri $uri/ /${site.index};\n        }"
    else "location / {\n            try_files $uri $uri/ =404;\n        }";

  mkStaticServer = _: site: ''
    server {
        listen 80;
        server_name ${lib.concatStringsSep " " site.serverNames};

        include /etc/nginx/conf.d/lib/http-security.conf;

        root ${site.mountPath};
        index ${site.index};

        ${staticSiteLocation site}
    }
  '';
in {
  proxyVhostType = proxyVhostType;
  staticSiteType = staticSiteType;

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
    name,
    serverNames,
    rootPath,
    mountPath ? "/srv/${name}",
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
        in "./site/${name}:${site.mountPath}:ro")
        (builtins.attrNames staticSites);
    };
}

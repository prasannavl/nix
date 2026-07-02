{
  mkIngressComposer = {
    lib,
    rateLimitProfiles,
    serviceRegistry,
    oauth2ProxyListenPort ? serviceRegistry.portFor "oauth2-proxy" "http",
  }: let
    registry = serviceRegistry;
    optional = cond: attrs:
      if cond
      then attrs
      else {};
    without = builtins.removeAttrs;
    withExtra = args: extra:
      (without args ["extra"]) // {extra = extra // (args.extra or {});};
    urlEncode = lib.strings.escapeURL;
    logoutPath = "/.abird/logout";
    edgeAuthCachePolicyResponseHeaders = {
      default = [];
      no-cache = [
        {
          name = "Cache-Control";
          value = ''"no-cache, private, max-age=0, must-revalidate"'';
        }
      ];
      no-store = [
        {
          name = "Cache-Control";
          value = ''"no-store, private, max-age=0"'';
        }
      ];
    };
    edgeAuthCachePolicyHeaders = policy:
      if builtins.hasAttr policy edgeAuthCachePolicyResponseHeaders
      then edgeAuthCachePolicyResponseHeaders.${policy}
      else throw "Unsupported edge auth cache policy: ${policy}";
    withEdgeAuthCachePolicy = args: let
      extra = args.extra or {};
      cachePolicy = args.edgeAuthCachePolicy or "default";
      cachePolicyHeaders = edgeAuthCachePolicyHeaders cachePolicy;
    in
      (without args ["edgeAuthCachePolicy" "extra"])
      // {
        extra =
          extra
          // optional (cachePolicyHeaders != []) {
            responseHeaders = cachePolicyHeaders ++ (extra.responseHeaders or []);
          };
      };

    mkEdgeAuth = clientMaxBodySize:
      {
        provider = "oauth2-proxy";
        upstream = "host.containers.internal:${toString oauth2ProxyListenPort}";
        resolver = null;
        externalScheme = "https";
        prefix = "/oauth2";
        passHeaders = true;
      }
      // optional (clientMaxBodySize != null) {
        # nginx checks the auth subrequest body limit before
        # proxy_pass_request_body off, so this must cover protected upload
        # routes on the same hostname.
        inherit clientMaxBodySize;
      };

    mkServiceProxy = {
      serviceName,
      hostGroup,
      portName ? "http",
      upstreamPortName ? portName,
      serverNames ? registry.domains.${hostGroup},
      upstreams ? registry.upstreamsForService serviceName upstreamPortName,
      authRequest ? null,
      useUpstreamCsp ? false,
      clientMaxBodySize ? null,
      timeout ? null,
      rateLimit ? rateLimitProfiles.web,
      extra ? {},
    }: let
      proxy =
        {
          service = null;
          port = registry.portFor serviceName portName;
          serverNames = serverNames;
          upstreams = upstreams;
          rateLimit = rateLimit;
        }
        // optional (authRequest != null) {authRequest = authRequest;}
        // optional useUpstreamCsp {useUpstreamCsp = true;}
        // optional (clientMaxBodySize != null) {clientMaxBodySize = clientMaxBodySize;}
        // extra;
    in
      if timeout == null
      then proxy
      else proxy // timeout;

    mkServiceRoute = {
      serviceName,
      hostGroup,
      path,
      portName ? "http",
      upstreamPortName ? portName,
      serverName ? registry.domainFor hostGroup,
      upstreams ? registry.upstreamsForService serviceName upstreamPortName,
      authRequest ? null,
      useUpstreamCsp ? true,
      clientMaxBodySize ? null,
      timeout ? null,
      rateLimit ? rateLimitProfiles.default,
      extra ? {},
    }: let
      route =
        {
          service = null;
          mode = "upstream";
          serverName = serverName;
          path = path;
          port = registry.portFor serviceName portName;
          upstreams = upstreams;
          rateLimit = rateLimit;
        }
        // optional (authRequest != null) {authRequest = authRequest;}
        // optional useUpstreamCsp {useUpstreamCsp = true;}
        // optional (clientMaxBodySize != null) {clientMaxBodySize = clientMaxBodySize;}
        // extra;
    in
      if timeout == null
      then route
      else route // timeout;

    mkCspServiceProxy = args:
      mkServiceProxy ({useUpstreamCsp = true;} // args);

    mkEdgeProtectedProxy = args: let
      authClientMaxBodySize = args.authClientMaxBodySize or null;
    in
      mkServiceProxy (withEdgeAuthCachePolicy ((without args ["authClientMaxBodySize"])
        // {
          authRequest = mkEdgeAuth authClientMaxBodySize;
          useUpstreamCsp = true;
        }));

    mkEdgeProtectedRoute = args: let
      authClientMaxBodySize =
        args.authClientMaxBodySize or (args.clientMaxBodySize or null);
    in
      mkServiceRoute (withEdgeAuthCachePolicy ((without args ["authClientMaxBodySize"])
        // {
          authRequest = mkEdgeAuth authClientMaxBodySize;
          useUpstreamCsp = true;
        }));

    mkHttpsServiceProxy = args @ {hostName, ...}: let
      proxyArgs = {portName = "https";} // without args ["hostName"];
    in
      mkCspServiceProxy (withExtra proxyArgs {
        upstreamProtocol = "https";
        upstreamHost = hostName;
        upstreamTlsName = hostName;
      });

    mkHttpsServiceRoute = args @ {hostName, ...}: let
      routeArgs = {portName = "https";} // without args ["hostName"];
    in
      mkServiceRoute (withExtra routeArgs {
        upstreamProtocol = "https";
        upstreamHost = hostName;
        upstreamTlsName = hostName;
      });

    mkStreamServiceProxy = protocol: {
      serviceName,
      portName,
      hostGroup ? null,
      upstreamPortName ? portName,
      listenPort ? registry.portFor serviceName portName,
      serverNames ?
        if hostGroup == null
        then []
        else registry.domains.${hostGroup},
      upstream ? registry.upstreamForService serviceName upstreamPortName,
      tcpTimeout ? registry.limits.tcpTimeouts.default or null,
      extra ? {},
    }: let
      streamTimeout =
        if protocol == "tcp" && tcpTimeout != null
        then {
          proxyConnectTimeout = tcpTimeout.connect;
          proxyTimeout = tcpTimeout.server;
        }
        else {};
    in
      {
        port = listenPort;
        protocols = [protocol];
        openFirewall = true;
        upstreamProtocol = protocol;
        upstreams = [upstream];
        nginxHostNames = serverNames;
      }
      // streamTimeout
      // extra;

    mkTcpServiceProxy = mkStreamServiceProxy "tcp";

    mkUdpServiceProxy = mkStreamServiceProxy "udp";

    mkOauth2ProxyRoute = args:
      mkServiceRoute (withExtra ({
          serviceName = "oauth2-proxy";
          hostGroup = "auth";
          upstreams = [(mkEdgeAuth null).upstream];
          useUpstreamCsp = false;
          rateLimit = rateLimitProfiles.web;
        }
        // args) {
        resolver = (mkEdgeAuth null).resolver;
        stripPath = false;
        proxyCookiePath = "/";
      });

    mkLogoutUrl = {
      hostGroup,
      path ? logoutPath,
      serverName ? registry.domainFor hostGroup,
    }: "https://${serverName}${path}";

    mkOauth2SignOutUrl = {
      hostGroup ? "auth",
      path ? "/oauth2/sign_out",
      serverName ? registry.domainFor hostGroup,
      rd,
    }: "https://${serverName}${path}?rd=${urlEncode rd}";

    mkLogoutChainRoute = {
      serviceName,
      hostGroup,
      nextUrl,
      upstreamPath,
      path ? logoutPath,
      portName ? "http",
      upstreamPortName ? portName,
      serverName ? registry.domainFor hostGroup,
      upstreams ? registry.upstreamsForService serviceName upstreamPortName,
      upstreamMethod ? "GET",
      upstreamBody ? null,
      requestHeaders ? [],
      upstreamRedirects ? ["~^(/.*)$"],
      continueStatuses ? [],
      rateLimit ? rateLimitProfiles.web,
      extra ? {},
    }:
      mkServiceRoute {
        inherit
          serviceName
          hostGroup
          path
          portName
          upstreamPortName
          serverName
          upstreams
          rateLimit
          ;
        extra =
          {
            location = "= ${path}";
            proxyCookiePath = "/";
            proxyMethod = upstreamMethod;
            proxyRewritePath = upstreamPath;
            proxyRedirects =
              map (from: {
                inherit from;
                to = nextUrl;
              })
              upstreamRedirects;
            errorRedirects =
              map (status: {
                inherit status;
                target = nextUrl;
              })
              continueStatuses;
          }
          // optional (upstreamBody != null) {
            proxyPassRequestBody = false;
            proxySetBody = upstreamBody;
          }
          // optional (requestHeaders != []) {inherit requestHeaders;}
          // extra;
      };

    logoutHopUrl = hop:
      mkLogoutUrl {
        hostGroup = hop.hostGroup;
        path = hop.path or logoutPath;
        serverName = hop.serverName or (registry.domainFor hop.hostGroup);
      };

    mkLogoutChainRoutes = {
      finalUrl,
      hops,
    }:
      builtins.listToAttrs (
        builtins.genList (
          index: let
            hop = builtins.elemAt hops index;
            nextUrl =
              hop.nextUrl
              or (
                if index + 1 < builtins.length hops
                then logoutHopUrl (builtins.elemAt hops (index + 1))
                else finalUrl
              );
          in {
            name = hop.name;
            value = mkLogoutChainRoute ((without hop ["name"]) // {inherit nextUrl;});
          }
        ) (builtins.length hops)
      );

    mergeServiceAttr = attrName: serviceConfigs:
      builtins.foldl' (acc: service: acc // (service.${attrName} or {})) {} serviceConfigs;

    concatServiceAttr = attrName: serviceConfigs:
      builtins.concatLists (map (service: service.${attrName} or []) serviceConfigs);
  in {
    inherit
      concatServiceAttr
      mergeServiceAttr
      mkCspServiceProxy
      mkEdgeAuth
      mkEdgeProtectedProxy
      mkEdgeProtectedRoute
      mkHttpsServiceProxy
      mkHttpsServiceRoute
      mkLogoutChainRoute
      mkLogoutChainRoutes
      mkLogoutUrl
      mkOauth2SignOutUrl
      mkOauth2ProxyRoute
      mkServiceProxy
      mkServiceRoute
      mkTcpServiceProxy
      mkUdpServiceProxy
      ;
    inherit logoutPath urlEncode;
  };
}

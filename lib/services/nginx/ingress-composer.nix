{
  mkIngressComposer = {
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
      serverNames ? registry.publicHosts.${hostGroup},
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
      serverName ? registry.publicHostFor hostGroup,
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
      mkServiceProxy ((without args ["authClientMaxBodySize"])
        // {
          authRequest = mkEdgeAuth authClientMaxBodySize;
          useUpstreamCsp = true;
        });

    mkEdgeProtectedRoute = args: let
      authClientMaxBodySize =
        args.authClientMaxBodySize or (args.clientMaxBodySize or null);
    in
      mkServiceRoute ((without args ["authClientMaxBodySize"])
        // {
          authRequest = mkEdgeAuth authClientMaxBodySize;
          useUpstreamCsp = true;
        });

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
      mkOauth2ProxyRoute
      mkServiceProxy
      mkServiceRoute
      ;
  };
}

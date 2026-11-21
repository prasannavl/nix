{
  validation,
  serviceRegistry,
  declarations ? {},
}: let
  inherit (validation.mk "invalid stack ingress declaration") require requireOnly uniqueStrings;
  isNonEmptyString = value: builtins.isString value && value != "";
  isPath = value: isNonEmptyString value && builtins.match "/.*" value != null;
  proxyFields = ["domain" "policy" "port" "requestBody" "response" "responseHeaderBufferSize" "rootRedirect" "service" "timeout" "upstream" "upstreamRedirects"];
  routeFields = ["domain" "logout" "match" "path" "policy" "port" "requestBody" "response" "responseHeaderBufferSize" "service" "target" "timeout" "upstream" "upstreamRedirects"];
  streamProxyFields = ["domain" "port" "protocol" "service"];
  staticSiteFields = ["domain" "file" "files" "hostNames" "routes"];
  staticFileFields = ["content" "path"];
  staticRouteFields = ["domain" "path"];
  httpRedirectFields = ["domain" "status" "to"];
  httpRedirectTargetFields = ["path" "service"];
  policyFields = ["auth" "authBodyLimit" "authCache" "csp" "rateLimit" "referrer"];
  rootRedirectFields = ["path" "status" "to"];
  upstreamFields = ["host" "protocol" "role" "tlsName"];
  upstreamRedirectFields = ["from" "preservePath" "source" "to"];
  upstreamRedirectSourceFields = ["domain" "kind" "scheme"];
  urlFields = ["domain" "path" "scheme"];
  logoutFields = ["auth" "loginPath"];
  matchFields = ["kind" "pattern"];
  requestBodyFields = ["buffering" "maxSize"];
  responseFields = ["buffering"];
  validRedirectStatus = status: builtins.elem status [301 302 303 307 308];
  validDomain = domain: isNonEmptyString domain && builtins.hasAttr domain serviceRegistry.domains;
  validService = service: isNonEmptyString service && builtins.hasAttr service serviceRegistry.services;
  validRole = role: isNonEmptyString role && builtins.hasAttr role serviceRegistry.roles;
  bodyLimitProfiles = (serviceRegistry.limits or {}).httpReqBodyLimits or {};
  timeoutProfiles = (serviceRegistry.limits or {}).timeouts or {};
  validBodyLimit = profile: isNonEmptyString profile && builtins.hasAttr profile bodyLimitProfiles;
  validTimeout = profile: isNonEmptyString profile && builtins.hasAttr profile timeoutProfiles;
  validPort = service: port: let
    probe =
      if validService service && isNonEmptyString port
      then builtins.tryEval (serviceRegistry.portFor service port)
      else {success = false;};
  in
    probe.success;
  normalizePolicy = kind: name: policy:
    assert require (builtins.isAttrs policy) "${kind} ${name} policy must be an attribute set";
    assert requireOnly policyFields policy "${kind} ${name} policy"; let
      auth = policy.auth or null;
      authBodyLimit = policy.authBodyLimit or null;
      authCache = policy.authCache or null;
      csp = policy.csp or null;
      rateLimit = policy.rateLimit or "web";
      referrer = policy.referrer or null;
    in
      assert require (builtins.elem auth [null "edge"]) "${kind} ${name} auth must be null or edge";
      assert require (authBodyLimit == null || validBodyLimit authBodyLimit) "${kind} ${name} authBodyLimit references an unknown body-limit profile";
      assert require (builtins.elem authCache [null "no-cache"]) "${kind} ${name} authCache must be null or no-cache";
      assert require ((authBodyLimit == null && authCache == null) || auth == "edge") "${kind} ${name} authBodyLimit/authCache require edge auth";
      assert require (builtins.elem csp [null "upstream"]) "${kind} ${name} csp must be null or upstream";
      assert require (builtins.elem rateLimit ["default" "web"]) "${kind} ${name} rateLimit must be default or web";
      assert require (builtins.elem referrer [null "upstream"]) "${kind} ${name} referrer must be null or upstream";
        {
          inherit auth csp rateLimit;
        }
        // (
          if policy ? authBodyLimit
          then {inherit authBodyLimit;}
          else {}
        )
        // (
          if policy ? authCache
          then {inherit authCache;}
          else {}
        )
        // (
          if policy ? referrer
          then {inherit referrer;}
          else {}
        );
  normalizeRedirect = name: redirect:
    if redirect == null
    then null
    else
      assert require (builtins.isAttrs redirect) "proxy ${name} rootRedirect must be null or an attribute set";
      assert requireOnly rootRedirectFields redirect "proxy ${name} rootRedirect"; let
        path = redirect.path or null;
        to = redirect.to or null;
      in
        assert require ((path == null) != (to == null)) "proxy ${name} rootRedirect must declare exactly one of path or to";
        assert require (path == null || isPath path) "proxy ${name} rootRedirect path must be absolute";
        assert require (builtins.isInt (redirect.status or null) && validRedirectStatus redirect.status) "proxy ${name} rootRedirect status is invalid";
          {
            inherit (redirect) status;
          }
          // (
            if path != null
            then {inherit path;}
            else {to = normalizeUrl "proxy" name to;}
          );
  normalizeUpstream = kind: name: upstream:
    assert require (builtins.isAttrs upstream) "${kind} ${name} upstream must be an attribute set";
    assert requireOnly upstreamFields upstream "${kind} ${name} upstream"; let
      protocol = upstream.protocol or null;
      host = upstream.host or null;
      role = upstream.role or null;
      tlsName = upstream.tlsName or null;
    in
      assert require (builtins.elem protocol [null "http" "https"]) "${kind} ${name} upstream protocol must be null, http, or https";
      assert require (host == null || host == "domain" || validDomain host) "${kind} ${name} upstream host must be null, domain, or a known domain group";
      assert require (role == null || validRole role) "${kind} ${name} upstream role references an unknown deployment role";
      assert require (builtins.elem tlsName [null "domain"]) "${kind} ${name} upstream tlsName must be null or domain";
      assert require (tlsName == null || protocol == "https") "${kind} ${name} upstream tlsName requires https";
        {
          inherit host protocol tlsName;
        }
        // (
          if role == null
          then {}
          else {inherit role;}
        );
  normalizeUrl = kind: name: url:
    assert require (builtins.isAttrs url) "${kind} ${name} URL must be an attribute set";
    assert requireOnly urlFields url "${kind} ${name} URL";
    assert require (builtins.elem (url.scheme or null) ["http" "https"]) "${kind} ${name} URL scheme must be http or https";
    assert require (validDomain (url.domain or null)) "${kind} ${name} URL references an unknown domain group";
    assert require (isPath (url.path or null)) "${kind} ${name} URL path must be absolute"; {
      inherit (url) domain path scheme;
    };
  normalizeUpstreamRedirectSource = kind: name: source:
    assert require (builtins.isAttrs source) "${kind} ${name} upstream redirect source must be an attribute set";
    assert requireOnly upstreamRedirectSourceFields source "${kind} ${name} upstream redirect source"; let
      sourceKind = source.kind or null;
      scheme = source.scheme or null;
      domain = source.domain or null;
    in
      assert require (builtins.elem sourceKind ["path" "url"]) "${kind} ${name} upstream redirect source kind must be path or url";
      assert require (sourceKind != "path" || (scheme == null && domain == null)) "${kind} ${name} path redirect source must not declare scheme or domain";
      assert require (sourceKind != "url" || builtins.elem scheme ["http" "https"]) "${kind} ${name} URL redirect source scheme must be http or https";
      assert require (sourceKind != "url" || validDomain domain) "${kind} ${name} URL redirect source references an unknown domain group";
        {kind = sourceKind;}
        // (
          if sourceKind == "url"
          then {inherit domain scheme;}
          else {}
        );
  normalizeUpstreamRedirect = kind: name: redirect:
    assert require (builtins.isAttrs redirect) "${kind} ${name} upstream redirect must be an attribute set";
    assert requireOnly upstreamRedirectFields redirect "${kind} ${name} upstream redirect"; let
      from = redirect.from or null;
      source = redirect.source or null;
      preservePath = redirect.preservePath or false;
      to = normalizeUrl kind name (redirect.to or {});
    in
      assert require ((from == null) != (source == null)) "${kind} ${name} upstream redirect must declare exactly one of from or source";
      assert require (from == null || isNonEmptyString from) "${kind} ${name} upstream redirect source must be non-empty";
      assert require (builtins.isBool preservePath) "${kind} ${name} upstream redirect preservePath must be boolean";
      assert require (!preservePath || to.path == "/") "${kind} ${name} preservePath redirect target path must be /";
        {
          inherit to;
        }
        // (
          if from != null
          then {inherit from;}
          else {source = normalizeUpstreamRedirectSource kind name source;}
        )
        // (
          if preservePath
          then {inherit preservePath;}
          else {}
        );
  normalizeUpstreamRedirects = kind: name: redirects:
    assert require (builtins.isList redirects) "${kind} ${name} upstreamRedirects must be a list";
      map (normalizeUpstreamRedirect kind name) redirects;
  normalizeLogout = name: logout:
    if logout == null
    then null
    else
      assert require (builtins.isAttrs logout) "route ${name} logout must be null or an attribute set";
      assert requireOnly logoutFields logout "route ${name} logout";
      assert require ((logout.auth or null) == "edge") "route ${name} logout auth must be edge";
      assert require (isPath (logout.loginPath or null)) "route ${name} logout loginPath must be absolute"; {
        auth = "edge";
        loginPath = logout.loginPath;
      };
  normalizeMatch = name: match:
    assert require (builtins.isAttrs match) "route ${name} match must be an attribute set";
    assert requireOnly matchFields match "route ${name} match"; let
      kind = match.kind or null;
    in
      assert require (builtins.elem kind ["regex" "exact"]) "route ${name} match kind must be regex or exact";
      assert require (isNonEmptyString (match.pattern or null)) "route ${name} match pattern must be non-empty"; {
        inherit kind;
        pattern = match.pattern;
      };
  normalizeRequestBody = kind: name: requestBody:
    assert require (builtins.isAttrs requestBody) "${kind} ${name} requestBody must be an attribute set";
    assert requireOnly requestBodyFields requestBody "${kind} ${name} requestBody"; let
      buffering = requestBody.buffering or null;
      maxSize = requestBody.maxSize or null;
    in
      assert require (builtins.elem buffering [null "stream"]) "${kind} ${name} requestBody buffering must be null or stream";
      assert require (maxSize == null || validBodyLimit maxSize) "${kind} ${name} requestBody maxSize references an unknown body-limit profile";
      assert require (buffering != null || maxSize != null) "${kind} ${name} requestBody must declare buffering or maxSize"; {
        inherit buffering maxSize;
      };
  normalizeResponse = kind: name: response:
    assert require (builtins.isAttrs response) "${kind} ${name} response must be an attribute set";
    assert requireOnly responseFields response "${kind} ${name} response"; let
      buffering = response.buffering or null;
    in
      assert require (buffering == "stream") "${kind} ${name} response buffering must be stream"; {
        inherit buffering;
      };
  normalizeHttpRedirectTarget = name: target:
    assert require (builtins.isAttrs target) "redirect ${name} target must be an attribute set";
    assert requireOnly httpRedirectTargetFields target "redirect ${name} target";
    assert require (validService (target.service or null)) "redirect ${name} target references an unknown service";
    assert require (isPath (target.path or null)) "redirect ${name} target path must be absolute"; {
      inherit (target) path service;
    };
  normalizeHttpRedirect = name: declaration:
    assert require (builtins.isAttrs declaration) "redirect ${name} must be an attribute set";
    assert requireOnly httpRedirectFields declaration "redirect ${name}";
    assert require (validDomain (declaration.domain or null)) "redirect ${name} references an unknown domain group";
    assert require (builtins.isInt (declaration.status or null) && validRedirectStatus declaration.status) "redirect ${name} status is invalid"; {
      domain = declaration.domain;
      status = declaration.status;
      to = normalizeHttpRedirectTarget name (declaration.to or {});
    };
  normalizeStaticFile = name: file:
    assert require (builtins.isAttrs file) "static site ${name} file must be an attribute set";
    assert requireOnly staticFileFields file "static site ${name} file";
    assert require (isNonEmptyString (file.path or null)) "static site ${name} file path must be non-empty";
    assert require (builtins.match "/.*" file.path == null) "static site ${name} file path must be relative";
    assert require (builtins.match ".*\\.\\..*" file.path == null) "static site ${name} file path must not contain parent traversal";
    assert require (builtins.isString (file.content or null)) "static site ${name} file content must be a string"; {
      inherit (file) content path;
    };
  normalizeStaticRoute = name: route:
    assert require (builtins.isAttrs route) "static site ${name} route must be an attribute set";
    assert requireOnly staticRouteFields route "static site ${name} route";
    assert require (validDomain (route.domain or null)) "static site ${name} route references an unknown domain group";
    assert require (isPath (route.path or null) && route.path != "/") "static site ${name} route path must be a non-root absolute path"; {
      inherit (route) domain path;
    };
  normalizeStaticSite = name: declaration:
    assert require (builtins.isAttrs declaration) "static site ${name} must be an attribute set";
    assert requireOnly staticSiteFields declaration "static site ${name}"; let
      domain = declaration.domain or null;
      hostNames = uniqueStrings "static site ${name} hostNames" (declaration.hostNames or []);
      hasFile = declaration ? file;
      hasFiles = declaration ? files;
      files =
        if hasFiles && builtins.isList declaration.files
        then map (normalizeStaticFile name) declaration.files
        else [];
      filePaths = uniqueStrings "static site ${name} file paths" (map (file: file.path) files);
      routes = declaration.routes or [];
    in
      assert require (domain == null || validDomain domain) "static site ${name} references an unknown domain group";
      assert require (domain != null || hostNames != []) "static site ${name} must declare a domain or hostNames";
      assert require (hasFile != hasFiles) "static site ${name} must declare exactly one of file or files";
      assert require (!hasFiles || builtins.isList declaration.files) "static site ${name} files must be a list";
      assert require (!hasFiles || filePaths != []) "static site ${name} files must not be empty";
      assert require (builtins.isList routes) "static site ${name} routes must be a list";
        (
          if hasFile
          then {file = normalizeStaticFile name declaration.file;}
          else {inherit files;}
        )
        // (
          if declaration ? hostNames
          then {inherit hostNames;}
          else {}
        )
        // (
          if domain != null
          then {inherit domain;}
          else {}
        )
        // (
          if declaration ? routes
          then {routes = map (normalizeStaticRoute name) routes;}
          else {}
        );
  normalizeProxy = name: declaration:
    assert require (builtins.isAttrs declaration) "proxy ${name} must be an attribute set";
    assert requireOnly proxyFields declaration "proxy ${name}"; let
      service = declaration.service or null;
      domain = declaration.domain or null;
      port = declaration.port or "http";
      policy = normalizePolicy "proxy" name (declaration.policy or {});
      rootRedirect = normalizeRedirect name (declaration.rootRedirect or null);
    in
      assert require (validService service) "proxy ${name} references an unknown service";
      assert require (validDomain domain) "proxy ${name} references an unknown domain group";
      assert require (isNonEmptyString port) "proxy ${name} port must be a non-empty string";
      assert require (validPort service port) "proxy ${name} references an unknown service port";
      assert require (!(declaration ? responseHeaderBufferSize) || isNonEmptyString declaration.responseHeaderBufferSize) "proxy ${name} responseHeaderBufferSize must be non-empty";
      assert require (!(declaration ? timeout) || validTimeout declaration.timeout) "proxy ${name} timeout references an unknown timeout profile";
        {
          inherit domain policy port rootRedirect service;
        }
        // (
          if declaration ? upstream
          then {upstream = normalizeUpstream "proxy" name declaration.upstream;}
          else {}
        )
        // (
          if declaration ? requestBody
          then {requestBody = normalizeRequestBody "proxy" name declaration.requestBody;}
          else {}
        )
        // (
          if declaration ? response
          then {response = normalizeResponse "proxy" name declaration.response;}
          else {}
        )
        // (
          if declaration ? responseHeaderBufferSize
          then {responseHeaderBufferSize = declaration.responseHeaderBufferSize;}
          else {}
        )
        // (
          if declaration ? upstreamRedirects
          then {upstreamRedirects = normalizeUpstreamRedirects "proxy" name declaration.upstreamRedirects;}
          else {}
        )
        // (
          if declaration ? timeout
          then {timeout = declaration.timeout;}
          else {}
        );
  normalizeRoute = name: declaration:
    assert require (builtins.isAttrs declaration) "route ${name} must be an attribute set";
    assert requireOnly routeFields declaration "route ${name}"; let
      target = declaration.target or "service";
      service = declaration.service or null;
      domain = declaration.domain or null;
      port = declaration.port or "http";
      path = declaration.path or null;
      policy = normalizePolicy "route" name (declaration.policy or {});
      logout = normalizeLogout name (declaration.logout or null);
    in
      assert require (builtins.elem target ["service" "edge-auth"]) "route ${name} target must be service or edge-auth";
      assert require (validDomain domain) "route ${name} references an unknown domain group";
      assert require (isPath path) "route ${name} path must be absolute";
      assert require (target != "service" || validService service) "route ${name} references an unknown service";
      assert require (target != "service" || (isNonEmptyString port && validPort service port)) "route ${name} references an unknown service port";
      assert require (target != "edge-auth" || service == null) "route ${name} edge-auth target must not declare a service";
      assert require (target != "edge-auth" || !(declaration ? upstream)) "route ${name} edge-auth target must not declare an upstream";
      assert require (target != "edge-auth" || !(declaration ? port)) "route ${name} edge-auth target must not declare a service port";
      assert require (target != "edge-auth" || !(declaration ? match)) "route ${name} edge-auth target must not declare a custom match";
      assert require (target != "edge-auth" || !(declaration ? requestBody)) "route ${name} edge-auth target must not declare request-body policy";
      assert require (target != "edge-auth" || !(declaration ? response)) "route ${name} edge-auth target must not declare response policy";
      assert require (target != "edge-auth" || !(declaration ? responseHeaderBufferSize)) "route ${name} edge-auth target must not declare a response header buffer";
      assert require (target != "edge-auth" || !(declaration ? timeout)) "route ${name} edge-auth target must not declare a timeout profile";
      assert require (target != "edge-auth" || !(declaration ? upstreamRedirects)) "route ${name} edge-auth target must not declare upstream redirects";
      assert require (target != "edge-auth" || policy.auth == null) "route ${name} edge-auth target must not declare an auth request policy";
      assert require (!(declaration ? responseHeaderBufferSize) || isNonEmptyString declaration.responseHeaderBufferSize) "route ${name} responseHeaderBufferSize must be non-empty";
      assert require (!(declaration ? timeout) || validTimeout declaration.timeout) "route ${name} timeout references an unknown timeout profile";
      assert require (logout == null || target == "service") "route ${name} logout policy requires a service target";
        {
          inherit domain logout path policy target;
          port =
            if target == "service"
            then port
            else null;
          service =
            if target == "service"
            then service
            else null;
        }
        // (
          if declaration ? match
          then {match = normalizeMatch name declaration.match;}
          else {}
        )
        // (
          if declaration ? requestBody
          then {requestBody = normalizeRequestBody "route" name declaration.requestBody;}
          else {}
        )
        // (
          if declaration ? upstream
          then {upstream = normalizeUpstream "route" name declaration.upstream;}
          else {}
        )
        // (
          if declaration ? response
          then {response = normalizeResponse "route" name declaration.response;}
          else {}
        )
        // (
          if declaration ? responseHeaderBufferSize
          then {responseHeaderBufferSize = declaration.responseHeaderBufferSize;}
          else {}
        )
        // (
          if declaration ? timeout
          then {timeout = declaration.timeout;}
          else {}
        )
        // (
          if declaration ? upstreamRedirects
          then {upstreamRedirects = normalizeUpstreamRedirects "route" name declaration.upstreamRedirects;}
          else {}
        );
  normalizeStreamProxy = name: declaration:
    assert require (builtins.isAttrs declaration) "stream proxy ${name} must be an attribute set";
    assert requireOnly streamProxyFields declaration "stream proxy ${name}"; let
      service = declaration.service or null;
      domain = declaration.domain or null;
      port = declaration.port or null;
      protocol = declaration.protocol or "tcp";
    in
      assert require (validService service) "stream proxy ${name} references an unknown service";
      assert require (validDomain domain) "stream proxy ${name} references an unknown domain group";
      assert require (isNonEmptyString port && validPort service port) "stream proxy ${name} references an unknown service port";
      assert require (builtins.elem protocol ["tcp" "udp"]) "stream proxy ${name} protocol must be tcp or udp"; {
        inherit domain port protocol service;
      };
  http = declarations.http or {};
  stream = declarations.stream or {};
in
  assert require (builtins.isAttrs declarations) "declarations must be an attribute set";
  assert requireOnly ["http" "stream"] declarations "declarations";
  assert require (builtins.isAttrs http) "declarations.http must be an attribute set";
  assert requireOnly ["proxies" "redirects" "routes" "staticSites"] http "declarations.http";
  assert require (builtins.isAttrs (http.proxies or {})) "declarations.http.proxies must be an attribute set";
  assert require (builtins.isAttrs (http.redirects or {})) "declarations.http.redirects must be an attribute set";
  assert require (builtins.isAttrs (http.routes or {})) "declarations.http.routes must be an attribute set";
  assert require (builtins.isAttrs (http.staticSites or {})) "declarations.http.staticSites must be an attribute set";
  assert require (builtins.isAttrs stream) "declarations.stream must be an attribute set";
  assert requireOnly ["proxies"] stream "declarations.stream";
  assert require (builtins.isAttrs (stream.proxies or {})) "declarations.stream.proxies must be an attribute set"; {
    http = {
      proxies = builtins.mapAttrs normalizeProxy (http.proxies or {});
      redirects = builtins.mapAttrs normalizeHttpRedirect (http.redirects or {});
      routes = builtins.mapAttrs normalizeRoute (http.routes or {});
      staticSites = builtins.mapAttrs normalizeStaticSite (http.staticSites or {});
    };
    stream.proxies = builtins.mapAttrs normalizeStreamProxy (stream.proxies or {});
  }

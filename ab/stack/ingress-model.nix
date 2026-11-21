let
  filterAttrs = predicate: attrs:
    builtins.listToAttrs (
      builtins.concatMap (
        name: let
          value = attrs.${name};
        in
          if predicate name value
          then [
            {
              inherit name value;
            }
          ]
          else []
      ) (builtins.attrNames attrs)
    );

  empty = {
    http = {
      proxies = {};
      routes = {};
      redirects = {};
      staticSites = {};
    };
    stream.proxies = {};
  };

  normalize = ingress: let
    http = ingress.http or {};
    stream = ingress.stream or {};
  in {
    http = {
      proxies = http.proxies or {};
      routes = http.routes or {};
      redirects = http.redirects or {};
      staticSites = http.staticSites or {};
    };
    stream.proxies = stream.proxies or {};
  };

  hasAny = hostnameSet: names:
    builtins.any (name: builtins.elem name hostnameSet) names;

  splitByServerNames = hostnameSet: ingress: let
    normalized = normalize ingress;
    isProxy = _: value: hasAny hostnameSet (value.serverNames or []);
    isRoute = _: value: builtins.elem (value.serverName or "") hostnameSet;
    isRedirect = _: value: hasAny hostnameSet (value.serverNames or []);
    isStaticSite = _: value: hasAny hostnameSet (value.serverNames or []);
  in {
    matched = {
      http = {
        proxies = filterAttrs isProxy normalized.http.proxies;
        routes = filterAttrs isRoute normalized.http.routes;
        redirects = filterAttrs isRedirect normalized.http.redirects;
        staticSites = filterAttrs isStaticSite normalized.http.staticSites;
      };
      stream.proxies = {};
    };
    rest = {
      http = {
        proxies = filterAttrs (name: value: !(isProxy name value)) normalized.http.proxies;
        routes = filterAttrs (name: value: !(isRoute name value)) normalized.http.routes;
        redirects = filterAttrs (name: value: !(isRedirect name value)) normalized.http.redirects;
        staticSites = filterAttrs (name: value: !(isStaticSite name value)) normalized.http.staticSites;
      };
      stream.proxies = normalized.stream.proxies;
    };
  };

  hasHttpEntries = ingress: let
    normalized = normalize ingress;
  in
    builtins.any
    (values: builtins.attrNames values != [])
    [
      normalized.http.proxies
      normalized.http.routes
      normalized.http.redirects
      normalized.http.staticSites
    ];
in {
  inherit empty hasHttpEntries normalize splitByServerNames;
}

{lib}: {
  ingressFromProxyVhosts = proxyVhosts:
    lib.foldl' lib.recursiveUpdate {} (
      lib.mapAttrsToList (
        _: proxy:
          lib.genAttrs proxy.serverNames (_: "http://127.0.0.1:${toString proxy.port}")
      )
      proxyVhosts
    );
}

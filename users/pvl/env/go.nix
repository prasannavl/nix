{
  nixos = _: {};

  home = {config, ...}: {
    home.sessionPath = [
      "${config.xdg.dataHome}/go/bin"
    ];

    home.sessionVariables = {
      GOPATH = "${config.xdg.dataHome}/go";
      GOMODCACHE = "${config.xdg.cacheHome}/go/mod";
      GOCACHE = "${config.xdg.cacheHome}/go/build";
    };
  };
}

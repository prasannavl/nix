{
  nixos = _: {};

  home = _: {
    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };
  };
}

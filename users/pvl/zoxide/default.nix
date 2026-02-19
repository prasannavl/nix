{
  nixos = {...}: {};

  home = {
    ...
  }: {
    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };
  };
}

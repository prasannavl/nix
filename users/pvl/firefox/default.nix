{
  nixos = _: {
    programs.firefox.enable = true;
  };

  home = _: {
    programs.firefox = {
      enable = true;
      profiles = {
        default = {
          settings = {
            "general.smoothScroll" = false;
          };
        };
      };
    };
  };
}

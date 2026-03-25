{
  nixos = {...}: {
    programs.firefox.enable = true;
  };

  home = {...}: {
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

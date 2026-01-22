{...}: {
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
}

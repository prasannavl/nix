{
  nixos = {...}: {
    programs.firefox.enable = true;
  };

  home = {
    lib,
    options,
    ...
  }: {
    programs.firefox =
      {
        enable = true;
        profiles = {
          default = {
            settings = {
              "general.smoothScroll" = false;
            };
          };
        };
      }
      // lib.optionalAttrs (options.programs.firefox ? configPath) {
        configPath = ".mozilla/firefox";
      };
  };
}

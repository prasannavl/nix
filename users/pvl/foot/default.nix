{
  nixos = {...}: {};

  home = {...}: {
    programs.foot = {
      enable = true;
      settings = {
        main = {
          font = "monospace:size=11.25";
        };
        text-bindings = {
          "\\x1b[13;2u" = "Shift+Return";
        };
      };
    };
  };
}

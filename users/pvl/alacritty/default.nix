let
  shiftEnterCsiU = builtins.fromJSON ''"\u001b[13;2u"'';
in {
  nixos = {...}: {};

  home = {pkgs, ...}: {
    programs.alacritty = {
      enable = true;
      settings = {
        # Default Alacritty sessions attach to tmux.
        terminal.shell = {
          program = "${pkgs.tmux}/bin/tmux";
        };

        keyboard.bindings = [
          {
            key = "Return";
            mods = "Shift";
            chars = shiftEnterCsiU;
          }
        ];
      };
    };
  };
}

{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    xsel
  ];

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";

    extraConfig = ''
      # set prefix: Alt + e
      set -g prefix M-e
      # Let's bind this too, so that repeated presses work, esp. when nesting.
      bind -n M-e send-prefix

      set -asg terminal-features ",alacritty*:256:RGB:mouse:cstyle"

      # start window numbering at 1
      set -g base-index 1
      set -g pane-base-index 1

      set -g mouse on
      setw -g mode-keys vi

      bind -n M-Left select-pane -L
      bind -n M-Right select-pane -R
      bind -n M-Up select-pane -U
      bind -n M-Down select-pane -D

      set -g history-limit 65536
    '';

    plugins = with pkgs.tmuxPlugins; [
      { plugin = sensible; }

      # keybind/layout helpers
      { plugin = pain-control; }
      { plugin = copycat; }
      { plugin = open; }

      # mouse/scroll behavior
      {
        plugin = better-mouse-mode;
        extraConfig = ''
          set -g @scroll-down-exit-copy-mode off
          set -g @scroll-without-changing-pane on
          set -g @emulate-scroll-for-no-mouse-alternate-buffer on
        '';
      }

      # clipboard / yank integration
      {
        plugin = yank;
        extraConfig = ''
          set -g @override_copy_command 'xsel -i' # workaround tmux-yank bug on wl-copy
          set -g @yank_selection 'primary'
          set -g @yank_selection_mouse 'primary'
          set -g @yank_action 'copy-pipe'
        '';
      }

      # ui
      { plugin = prefix-highlight; }

      # session persistence
      { plugin = resurrect; }
      { plugin = continuum; }

      # others
      { plugin = logging; }
      { plugin = tmux-thumbs; }
    ];
  };
}

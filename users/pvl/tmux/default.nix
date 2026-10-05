{
  nixos = {...}: {
    programs.tmux.enable = true;
  };

  home = {pkgs, ...}: {
    programs.tmux = {
      enable = true;
      terminal = "tmux-256color";

      extraConfig = ''
        # prefix: Alt+e; repeat works when nested
        set -g prefix M-e
        bind M-e send-prefix

        # modified Enter for TUIs (codex); csi-u extended keys
        set -g xterm-keys on
        set -g extended-keys always
        set -g extended-keys-format csi-u
        set -asg terminal-features ",xterm*:extkeys,alacritty*:256:RGB:mouse:cstyle:extkeys,kitty*:extkeys,wezterm*:extkeys"

        # windows/panes from 1; deep scrollback
        set -g base-index 1
        set -g pane-base-index 1
        set -g history-limit 65536

        set -g mouse on
        setw -g mode-keys vi

        # inlined sensible: timers, focus-events, aggressive-resize, win cycling, reload
        set -g display-time 4000
        set -g status-interval 5
        setw -g focus-events on
        setw -g aggressive-resize on
        bind C-n next-window
        bind C-p previous-window
        bind R source-file ~/.config/tmux/tmux.conf \; display-message "tmux.conf reloaded"

        # inlined pain-control: full set
        bind h select-pane -L
        bind j select-pane -D
        bind k select-pane -U
        bind l select-pane -R
        bind C-h select-pane -L
        bind C-j select-pane -D
        bind C-k select-pane -U
        bind C-l select-pane -R
        # own: Alt+arrows, no prefix
        bind -n M-Left select-pane -L
        bind -n M-Right select-pane -R
        bind -n M-Up select-pane -U
        bind -n M-Down select-pane -D
        # resize: repeatable, 5 cells
        bind -r H resize-pane -L 5
        bind -r J resize-pane -D 5
        bind -r K resize-pane -U 5
        bind -r L resize-pane -R 5
        bind -r '<' swap-window -d -t -1
        bind -r '>' swap-window -d -t +1
        # splits inherit pane cwd
        bind '%' split-window -h -c "#{pane_current_path}"
        bind '"' split-window -v -c "#{pane_current_path}"
        bind '|' split-window -h -c "#{pane_current_path}"
        bind '\' split-window -fh -c "#{pane_current_path}"
        bind '-' split-window -v -c "#{pane_current_path}"
        bind '_' split-window -fv -c "#{pane_current_path}"
        bind c new-window -c "#{pane_current_path}"

        # inlined better-mouse-mode: wheel -> app | alt-screen | copy-mode; keep pane; no exit at bottom; 3 lines/notch
        bind -n WheelUpPane if -F '#{mouse_any_flag}' { send-keys -M } { if -F '#{alternate_on}' { send-keys -t= up ; send-keys -t= up ; send-keys -t= up } { if -F '#{pane_in_mode}' { send-keys -M ; send-keys -M ; send-keys -M } { copy-mode -t= ; send-keys -M ; send-keys -M ; send-keys -M } } }
        bind -n WheelDownPane if -F '#{mouse_any_flag}' { send-keys -M } { if -F '#{alternate_on}' { send-keys -t= down ; send-keys -t= down ; send-keys -t= down } { send-keys -M ; send-keys -M ; send-keys -M } }
        bind -T copy-mode WheelUpPane send -N3 -X scroll-up
        bind -T copy-mode WheelDownPane send -N3 -X scroll-down
        bind -T copy-mode-vi WheelUpPane send -N3 -X scroll-up
        bind -T copy-mode-vi WheelDownPane send -N3 -X scroll-down

        # inlined yank: stock copy + set-clipboard=external => OSC52 => terminal clipboard; wl-copy only for no-newline
        bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
        bind -T copy-mode y send-keys -X copy-selection-and-cancel
        bind -T copy-mode-vi Y send-keys -X copy-pipe-and-cancel "tmux paste-buffer -p"
        bind -T copy-mode Y send-keys -X copy-pipe-and-cancel "tmux paste-buffer -p"
        bind -T copy-mode-vi '!' send-keys -X copy-pipe "wl-copy --trim-newline"
        bind -T copy-mode '!' send-keys -X copy-pipe "wl-copy --trim-newline"
        # prefix y: pane last non-empty line; Y: pane cwd
        bind y run-shell "tmux capture-pane -pJ | grep -v '^[[:space:]]*$' | tail -n 1 | sed -e 's/^[[:space:]]*//' | wl-copy --trim-newline"
        bind Y run-shell "tmux display-message -p -F '#{pane_current_path}' | wl-copy --trim-newline"

        # inlined open: o = xdg-open selection; C-o = $EDITOR
        bind -T copy-mode-vi o send-keys -X copy-pipe-and-cancel "xargs -I {} xdg-open {}"
        bind -T copy-mode o send-keys -X copy-pipe-and-cancel "xargs -I {} xdg-open {}"
        bind -T copy-mode-vi C-o send-keys -X copy-pipe-and-cancel "xargs -I {} tmux send-keys 'vi -- {}' C-m"
        bind -T copy-mode C-o send-keys -X copy-pipe-and-cancel "xargs -I {} tmux send-keys 'vi -- {}' C-m"

        # inlined logging: all output under ~/tmp; P toggle, M-p screen, M-P history, M-c clear
        bind P if -F '#{pane_pipe}' { pipe-pane ; display-message "pane logging stopped" } { pipe-pane -o "mkdir -p ~/tmp; cat >> ~/tmp/tmux-#{session_name}-#{window_index}-#{pane_index}-$(date +%Y%m%dT%H%M%S).log" ; display-message "pane logging to ~/tmp" }
        bind M-p run-shell "mkdir -p ~/tmp && tmux capture-pane -pJ -t #{pane_id} > ~/tmp/tmux-screen-#{session_name}-#{window_index}-#{pane_index}.txt"
        bind M-P run-shell "mkdir -p ~/tmp && tmux capture-pane -pJ -S - -t #{pane_id} > ~/tmp/tmux-history-#{session_name}-#{window_index}-#{pane_index}.txt"
        bind M-c clear-history

        # inlined prefix-highlight: client_prefix in status-left
        set -g status-left '#{?client_prefix,#[reverse] PREFIX #[noreverse],}[#{session_name}] '
      '';

      plugins = [
        {
          plugin = pkgs.tmuxPlugins.fingers;
          extraConfig = ''
            # prefix+Space (was thumbs); prefix+J = jump mode
            set -g @fingers-key Space
          '';
        }

        {plugin = pkgs.tmuxPlugins.resurrect;}
      ];
    };
  };
}

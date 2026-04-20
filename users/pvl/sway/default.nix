{
  nixos = {pkgs, ...}: {
    xdg.portal.wlr = let
      xdpwChooser = pkgs.writeShellApplication {
        name = "sway-xdpw-chooser";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.fuzzel
          pkgs.gawk
          pkgs.gnugrep
          pkgs.slurp
          pkgs.wmenu
        ];
        text = ''
          set -Eeuo pipefail

          cache_dir="''${XDG_RUNTIME_DIR:-/tmp}/xdpw-chooser"
          chooser_file=""

          cleanup() {
            if [[ -n "''${chooser_file:-}" ]]; then
              rm -f -- "$chooser_file"
            fi
          }

          ensure_cache_dir() {
            mkdir -p "$cache_dir"
          }

          cache_key() {
            cksum < "$chooser_file" | awk '{ print $1 ":" $2 }'
          }

          read_cached_selection() {
            local key cache_file now saved_at saved_value
            key="$(cache_key)"
            cache_file="$cache_dir/$key"

            [[ -f "$cache_file" ]] || return 1

            now="$(date +%s)"
            IFS=$'\t' read -r saved_at saved_value < "$cache_file" || return 1
            [[ -n "$saved_at" && -n "$saved_value" ]] || return 1
            (( now - saved_at <= 15 )) || return 1

            printf '%s\n' "$saved_value"
          }

          write_cached_selection() {
            local key cache_file now selection
            selection="$1"
            [[ -n "$selection" ]] || return 0

            key="$(cache_key)"
            cache_file="$cache_dir/$key"
            now="$(date +%s)"
            printf '%s\t%s\n' "$now" "$selection" > "$cache_file"
          }

          run_menu() {
            local selection

            if [[ ! -s "$chooser_file" ]]; then
              return 0
            fi

            if selection="$(read_cached_selection)"; then
              printf '%s\n' "$selection"
              return 0
            fi

            if command -v fuzzel >/dev/null 2>&1; then
              selection="$(fuzzel --dmenu --prompt='Share: ' --no-exit-on-keyboard-focus-loss < "$chooser_file" || true)"
              write_cached_selection "$selection"
              printf '%s\n' "$selection"
              return
            fi

            if command -v wmenu >/dev/null 2>&1; then
              selection="$(wmenu -p 'Share: ' < "$chooser_file" || true)"
              write_cached_selection "$selection"
              printf '%s\n' "$selection"
              return
            fi

            if command -v wofi >/dev/null 2>&1; then
              selection="$(wofi --show dmenu --prompt 'Share: ' < "$chooser_file" || true)"
              write_cached_selection "$selection"
              printf '%s\n' "$selection"
              return
            fi

            if command -v rofi >/dev/null 2>&1; then
              selection="$(rofi -dmenu -p 'Share: ' < "$chooser_file" || true)"
              write_cached_selection "$selection"
              printf '%s\n' "$selection"
              return
            fi

            if command -v bemenu >/dev/null 2>&1; then
              selection="$(bemenu -p 'Share: ' < "$chooser_file" || true)"
              write_cached_selection "$selection"
              printf '%s\n' "$selection"
              return
            fi

            return 127
          }

          run_slurp_for_monitors() {
            local output_name
            output_name="$(slurp -f '%o' -or 2>/dev/null || true)"
            if [[ -z "$output_name" ]]; then
              return 0
            fi

            awk -v output_name="$output_name" '
              index($0, "Monitor: " output_name " ") == 1 || $0 == "Monitor: " output_name {
                print
                exit
              }
            ' "$chooser_file"
          }

          wants_visual_monitor_picker() {
            [[ -s "$chooser_file" ]] || return 1
            ! grep -q '^Window: ' "$chooser_file"
          }

          choose_entry() {
            cat > "$chooser_file"

            ensure_cache_dir

            if wants_visual_monitor_picker; then
              run_slurp_for_monitors
              return
            fi

            run_menu
          }

          main() {
            chooser_file="$(mktemp)"
            trap cleanup EXIT
            choose_entry || true
          }

          main "$@"
        '';
      };
    in {
      enable = true;
      settings.screencast = {
        chooser_type = "dmenu";
        chooser_cmd = "${xdpwChooser}/bin/sway-xdpw-chooser";
      };
    };

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-wlr
    ];
  };

  home = {pkgs, ...}: {
    imports = [
      ./config.nix
    ];

    xdg.portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-wlr
        pkgs.xdg-desktop-portal-gtk
      ];
      config = {
        common.default = "gtk";
        sway = {
          default = ["wlr" "gtk"];
        };
      };
    };

    # Setting this causes gnome's
    # xwayland-native-scaling to not work well.
    # cursor sizes are double divided.
    #
    # home.pointerCursor = {
    #   name = "Adwaita";
    #   package = pkgs.adwaita-icon-theme;
    #   size = 24;
    #   x11.enable = true;
    #   # dotIcons.enable = true;
    # };
  };
}

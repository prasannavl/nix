{
  nixos = {...}: {};

  home = {...}: {
    programs.ranger = {
      enable = true;
      extraConfig = ''
        set preview_images true
        set preview_images_method kitty
        set use_preview_script true
        set wrap_scroll true
        set preview_files true
        set preview_directories true
        set use_preview_script true
        default_linemode sizemtime
        set cd_tab_fuzzy true
        set draw_borders false
      '';
    };
  };
}

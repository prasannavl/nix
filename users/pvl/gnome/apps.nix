{
  dconf.settings = {
    "org/gnome/nautilus/icon-view" = {
      default-zoom-level = "small-plus";
      # captions = []; # size, permissions
    };
    "org/gnome/nautilus/preferences" = {
      show-create-link = true;
      show-delete-permanently = true;
    };
    "org/gnome/nautilus/list-view" = {
      default-visible-columns = [
        "name"
        "size"
        "owner"
        "group"
        "permissions"
        "date_modified"
      ];
    };
    "org/gnome/Console" = {
      shell = ["tmux"];
    };
  };
}

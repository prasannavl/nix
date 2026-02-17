{
  config,
  lib,
  pkgs,
  ...
}: {
  home.preferXdgDirectories = true;

  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
  };
  programs.fzf.enable = true;

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
    };
  };

  home.packages = with pkgs; [
    atool
  ];

  home.activation.cloneDotfiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
    repo_url="https://github.com/prasannavl/dotfiles.git"
    dotfiles_dir="${config.home.homeDirectory}/dotfiles"

    if [ -d "$dotfiles_dir/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$dotfiles_dir" fetch --all --prune
      $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$dotfiles_dir" pull --ff-only
    else
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "${config.home.homeDirectory}"
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone "$repo_url" "$dotfiles_dir"
    fi
  '';

  home.activation.linkEditableBin = lib.hm.dag.entryAfter ["cloneDotfiles"] ''
    dotfiles_dir="${config.home.homeDirectory}/dotfiles"
    bin_link="${config.home.homeDirectory}/bin"

    if [ -e "$bin_link" ] && [ ! -L "$bin_link" ]; then
      echo "Refusing to replace non-symlink path: $bin_link" >&2
      exit 1
    fi

    $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$dotfiles_dir/bin" "$bin_link"
  '';

  # The state version is required and should stay at the version you
  # originally installed.
  home.stateVersion = "25.11";
}

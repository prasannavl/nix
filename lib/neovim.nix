{pkgs, ...}: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    viAlias = true;
    configure = {
      customLuaRC = ''
        vim.g.mapleader = " "
        require("lazy").setup({
          spec = {
            {
              "LazyVim/LazyVim",
              dir = "${pkgs.vimPlugins.LazyVim}",
              import = "lazyvim.plugins",
            },
          { import = "lazyvim.plugins.extras.lang.rust" },
          { import = "plugins.user" },
          },
        })
      '';

      packages.myVimPackage = with pkgs.vimPlugins; {
        start = [
          LazyVim
        ];
        opt = [ ];
      };

      runtime."lua/plugins/user.lua".text = ''
        return {
          {
            "LazyVim/LazyVim",
            opts = {
              colorscheme = "catppuccin",
            },
          }
        }
      '';
    };
  };

  # keep CLI deps here (not plugins)
  environment.systemPackages = with pkgs; [
    git ripgrep fd gcc
  ];
}

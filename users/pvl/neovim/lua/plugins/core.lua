return {
  -- essentials
  { "tpope/vim-rsi" }, -- cmd line like key bindings
  { "tpope/vim-sleuth" }, -- auto shift width, tab stop
  { "lewis6991/satellite.nvim" }, -- scrollbar
  { "tpope/vim-fugitive" }, -- git
  { "sindrets/diffview.nvim" }, -- git diffview

  -- ai
  {
    "olimorris/codecompanion.nvim",
    opts = {},
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
  },

  -- lang stuff
  { "NoahTheDuke/vim-just", lazy = true },
  { "IndianBoy42/tree-sitter-just", lazy = true },

  -- themes
  -- { "ellisonleao/gruvbox.nvim" },

  -- lazyvim overrides
  {
    "nvim-mini/mini.surround",
    opts = {
      mappings = {
        add = "gsa",
        delete = "gsd",
        find = "gsf",
        find_left = "gsF",
        highlight = "gsh",
        replace = "gsr",
        update_n_lines = "gsn",
      },
    },
  },
  {
    "folke/noice.nvim",
    enabled = false,
    opts = {
      cmdline = {
        view = "cmdline",
      },
    },
  },

  -- todo
  -- { "epwalsh/obsidian.nvim" },
  -- { "preservim/vim-pencil" },
}

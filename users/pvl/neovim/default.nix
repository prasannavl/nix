let
  sensibleConfig = ''
    vim.g.mapleader = " "
    vim.g.maplocalleader = ","
    vim.g.have_nerd_font = true
    vim.g.snacks_animate = false

    if vim.loader then
      vim.loader.enable()
    end

    local map = vim.keymap.set

    map("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })
    map("n", "<leader>qq", "<cmd>qa<cr>", { desc = "Quit all" })
    map("n", "<leader>ww", "<cmd>w<cr>", { desc = "Write" })
    map("n", "<leader>wq", "<cmd>wq<cr>", { desc = "Write and quit" })
    map("n", "<C-Left>", "b", { desc = "Last word" })
    map("n", "<C-Right>", "w", { desc = "Next word" })
    map("i", "<C-BS>", "<C-w>", { desc = "Backspace last word", remap = false })
    map("i", "<C-h>", "<C-w>", { desc = "Backspace last word", remap = false })
  '';

  baseConfig = ''
    vim.opt.autowrite = true
    vim.opt.breakindent = true
    vim.opt.clipboard = "unnamedplus"
    vim.opt.confirm = true
    vim.opt.cursorline = true
    vim.opt.expandtab = true
    vim.opt.ignorecase = true
    vim.opt.inccommand = "split"
    vim.opt.linebreak = true
    vim.opt.list = true
    vim.opt.mouse = "a"
    vim.opt.number = true
    vim.opt.relativenumber = true
    vim.opt.scrolloff = 6
    vim.opt.shiftround = true
    vim.opt.shiftwidth = 4
    vim.opt.shortmess:append({ W = true, c = true })
    vim.opt.sidescrolloff = 8
    vim.opt.signcolumn = "yes"
    vim.opt.smartcase = true
    vim.opt.smartindent = true
    vim.opt.smoothscroll = false
    vim.opt.splitbelow = true
    vim.opt.splitright = true
    vim.opt.softtabstop = -1
    vim.opt.tabstop = 4
    vim.opt.termguicolors = true
    vim.opt.timeoutlen = 300
    vim.opt.undofile = true
    vim.opt.updatetime = 200
    vim.opt.virtualedit = "block"
    vim.opt.winminwidth = 5
    vim.opt.wrap = true

    vim.opt.whichwrap:append({
      ["<"] = true,
      [">"] = true,
      ["["] = true,
      ["]"] = true,
      h = true,
      l = true,
    })

    vim.opt.fillchars = {
      foldopen = "v",
      foldclose = ">",
      fold = " ",
      foldsep = " ",
      diff = "/",
      eob = " ",
    }

    vim.opt.listchars = {
      tab = "> ",
      trail = "-",
      nbsp = "+",
    }

    vim.diagnostic.config({
      severity_sort = true,
      signs = true,
      underline = true,
      update_in_insert = false,
      virtual_text = {
        spacing = 2,
        source = "if_many",
      },
    })

    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("pvl_cdpwd", { clear = true }),
      pattern = "*",
      callback = function()
        local dir = vim.fn.expand("%:p:h")
        if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
          vim.api.nvim_set_current_dir(dir)
        end
      end,
    })

    if vim.env.WAYLAND_DISPLAY == nil and vim.env.DISPLAY == nil then
      local on_real_tty = vim.env.XDG_SESSION_TYPE == "tty" or vim.env.TERM == "linux"
      if on_real_tty then
        vim.opt.termguicolors = false
        vim.cmd.colorscheme("default")
      end
    end
  '';
in {
  inherit baseConfig sensibleConfig;

  nixos = {...}: {};

  home = {lib, ...}: let
    initLua = lib.concatStringsSep "\n\n" [
      sensibleConfig
      baseConfig
    ];
  in {
    programs.neovim = {
      enable = lib.mkDefault true;
      defaultEditor = lib.mkDefault true;
      viAlias = lib.mkDefault true;
      vimAlias = lib.mkDefault true;
      withPython3 = lib.mkDefault false;
      withRuby = lib.mkDefault false;

      initLua = initLua;
    };

    xdg.configFile."nvim/init.lua" = {
      text = lib.mkDefault "";
      force = lib.mkDefault true;
    };
  };
}

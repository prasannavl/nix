{
  nixos = {...}: {};

  home = {
    lib,
    pkgs,
    ...
  }: let
    enabledPlugins = {
      noice = false;
    };

    isPluginEnabled = name: enabledPlugins.${name} or true;

    sensibleConfig = ''
      vim.g.mapleader = " "
      vim.g.maplocalleader = ","
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
      vim.opt.completeopt = "menu,menuone,noselect"
      vim.opt.confirm = true
      vim.opt.cursorline = true
      vim.opt.expandtab = true
      vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
      vim.opt.foldlevel = 99
      vim.opt.foldmethod = "expr"
      vim.opt.ignorecase = true
      vim.opt.inccommand = "split"
      vim.opt.laststatus = 3
      vim.opt.linebreak = true
      vim.opt.list = true
      vim.opt.mouse = "a"
      vim.opt.number = true
      vim.opt.pumblend = 10
      vim.opt.relativenumber = true
      vim.opt.scrolloff = 6
      vim.opt.shiftround = true
      vim.opt.shiftwidth = 4
      vim.opt.shortmess:append({ W = true, c = true })
      vim.opt.showmode = false
      vim.opt.sidescrolloff = 8
      vim.opt.signcolumn = "yes"
      vim.opt.smartcase = true
      vim.opt.smartindent = true
      vim.opt.smoothscroll = true
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
    '';

    pluginSpecs = {
      schemaStore = {
        package = pkgs.vimPlugins.SchemaStore-nvim;
      };

      blinkCmp = {
        package = pkgs.vimPlugins.blink-cmp;
        config = ''
          require("blink.cmp").setup({
            keymap = { preset = "default" },
            appearance = { nerd_font_variant = "mono" },
            completion = {
              documentation = { auto_show = true, auto_show_delay_ms = 250 },
              ghost_text = { enabled = true },
            },
            signature = { enabled = true },
            sources = {
              default = { "lsp", "path", "snippets", "buffer" },
            },
            fuzzy = { implementation = "prefer_rust" },
          })
        '';
      };

      bufferline = {
        package = pkgs.vimPlugins.bufferline-nvim;
        config = ''
          require("bufferline").setup({
            options = {
              diagnostics = "nvim_lsp",
              separator_style = "thin",
              show_buffer_close_icons = false,
              show_close_icon = false,
            },
          })
          map("n", "<S-h>", "<cmd>BufferLineCyclePrev<cr>", { desc = "Previous buffer" })
          map("n", "<S-l>", "<cmd>BufferLineCycleNext<cr>", { desc = "Next buffer" })
        '';
      };

      catppuccin = {
        package = pkgs.vimPlugins.catppuccin-nvim;
        config = ''
          require("catppuccin").setup({
            flavour = "mocha",
            integrations = {
              blink_cmp = true,
              gitsigns = true,
              lsp_trouble = true,
              treesitter = true,
              which_key = true,
            },
          })
          vim.cmd.colorscheme("catppuccin")
          if vim.env.WAYLAND_DISPLAY == nil and vim.env.DISPLAY == nil then
            local on_real_tty = vim.env.XDG_SESSION_TYPE == "tty" or vim.env.TERM == "linux"
            if on_real_tty then
              vim.opt.termguicolors = false
              vim.cmd.colorscheme("default")
            end
          end
        '';
      };

      codecompanion = {
        package = pkgs.vimPlugins.codecompanion-nvim;
        config = ''
          require("codecompanion").setup({
            interactions = {
              chat = { adapter = "openai" },
              inline = { adapter = "openai" },
              cmd = { adapter = "openai" },
            },
            opts = {
              log_level = "ERROR",
            },
          })
          map({ "n", "v" }, "<leader>aa", "<cmd>CodeCompanionChat Toggle<cr>", { desc = "AI chat" })
          map("v", "<leader>ad", "<cmd>CodeCompanionChat Add<cr>", { desc = "AI add selection" })
          map({ "n", "v" }, "<leader>ai", "<cmd>CodeCompanion<cr>", { desc = "AI inline" })
          map("n", "<leader>ac", "<cmd>CodeCompanionActions<cr>", { desc = "AI actions" })
        '';
      };

      conform = {
        package = pkgs.vimPlugins.conform-nvim;
        config = ''
          require("conform").setup({
            formatters_by_ft = {
              bash = { "shfmt" },
              css = { "prettierd", "prettier", stop_after_first = true },
              go = { "goimports", "gofumpt" },
              html = { "prettierd", "prettier", stop_after_first = true },
              javascript = { "prettierd", "prettier", stop_after_first = true },
              javascriptreact = { "prettierd", "prettier", stop_after_first = true },
              json = { "biome", "prettierd", "prettier", stop_after_first = true },
              lua = { "stylua" },
              markdown = { "deno_fmt" },
              nix = { "alejandra" },
              python = { "ruff_fix", "ruff_format" },
              rust = { "rustfmt" },
              sh = { "shfmt" },
              sql = { "sqlfluff" },
              terraform = { "terraform_fmt" },
              toml = { "taplo" },
              typescript = { "prettierd", "prettier", stop_after_first = true },
              typescriptreact = { "prettierd", "prettier", stop_after_first = true },
              yaml = { "prettierd", "prettier", stop_after_first = true },
            },
            format_on_save = function(bufnr)
              local disabled = { c = true, cpp = true }
              if disabled[vim.bo[bufnr].filetype] then
                return nil
              end
              return {
                timeout_ms = 2500,
                lsp_format = "fallback",
              }
            end,
          })
          map({ "n", "v" }, "<leader>cf", function()
            require("conform").format({ async = true, lsp_format = "fallback" })
          end, { desc = "Format" })
        '';
      };

      dressing = {
        package = pkgs.vimPlugins.dressing-nvim;
        config = ''
          require("dressing").setup()
        '';
      };

      flash = {
        package = pkgs.vimPlugins.flash-nvim;
        config = ''
          require("flash").setup()
          map({ "n", "x", "o" }, "s", function()
            require("flash").jump()
          end, { desc = "Flash" })
          map({ "n", "x", "o" }, "S", function()
            require("flash").treesitter()
          end, { desc = "Flash treesitter" })
          map({ "o" }, "r", function()
            require("flash").remote()
          end, { desc = "Remote flash" })
          map({ "o", "x" }, "R", function()
            require("flash").treesitter_search()
          end, { desc = "Treesitter search" })
        '';
      };

      friendlySnippets = {
        package = pkgs.vimPlugins.friendly-snippets;
      };

      gitsigns = {
        package = pkgs.vimPlugins.gitsigns-nvim;
        config = ''
          require("gitsigns").setup({
            current_line_blame = true,
            current_line_blame_opts = { delay = 500 },
            on_attach = function(bufnr)
              local gs = package.loaded.gitsigns
              local function opts(desc)
                return { buffer = bufnr, desc = desc }
              end
              map("n", "]h", gs.next_hunk, opts("Next hunk"))
              map("n", "[h", gs.prev_hunk, opts("Previous hunk"))
              map("n", "<leader>ghs", gs.stage_hunk, opts("Stage hunk"))
              map("n", "<leader>ghr", gs.reset_hunk, opts("Reset hunk"))
              map("v", "<leader>ghs", function()
                gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
              end, opts("Stage hunk"))
              map("v", "<leader>ghr", function()
                gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
              end, opts("Reset hunk"))
              map("n", "<leader>ghp", gs.preview_hunk, opts("Preview hunk"))
              map("n", "<leader>ghb", gs.blame_line, opts("Blame line"))
              map("n", "<leader>ghd", gs.diffthis, opts("Diff this"))
            end,
          })
        '';
      };

      grugFar = {
        package = pkgs.vimPlugins.grug-far-nvim;
        config = ''
          require("grug-far").setup({
            headerMaxWidth = 80,
          })
          map("n", "<leader>sr", function()
            require("grug-far").open()
          end, { desc = "Search and replace" })
          map("v", "<leader>sr", function()
            require("grug-far").open({ prefills = { paths = vim.fn.expand("%") } })
          end, { desc = "Search and replace selection" })
        '';
      };

      lazydev = {
        package = pkgs.vimPlugins.lazydev-nvim;
        config = ''
          require("lazydev").setup({
            library = {
              { path = "luvit-meta/library", words = { "vim%.uv" } },
            },
          })
        '';
      };

      lualine = {
        package = pkgs.vimPlugins.lualine-nvim;
        config = ''
          require("lualine").setup({
            options = {
              component_separators = "",
              globalstatus = true,
              section_separators = "",
              theme = "auto",
            },
            sections = {
              lualine_c = {
                { "filename", path = 1 },
              },
              lualine_x = {
                "diagnostics",
                "encoding",
                "filetype",
              },
            },
          })
        '';
      };

      luasnip = {
        package = pkgs.vimPlugins.luasnip;
      };

      miniAi = {
        package = pkgs.vimPlugins.mini-ai;
        config = ''
          require("mini.ai").setup({ n_lines = 500 })
        '';
      };

      miniBufremove = {
        package = pkgs.vimPlugins.mini-bufremove;
        config = ''
          map("n", "<leader>bd", function()
            require("mini.bufremove").delete(0, false)
          end, { desc = "Delete buffer" })
          map("n", "<leader>bD", function()
            require("mini.bufremove").delete(0, true)
          end, { desc = "Force delete buffer" })
        '';
      };

      miniComment = {
        package = pkgs.vimPlugins.mini-comment;
        config = ''
          require("mini.comment").setup()
        '';
      };

      miniDiff = {
        package = pkgs.vimPlugins.mini-diff;
        config = ''
          require("mini.diff").setup()
        '';
      };

      miniIcons = {
        package = pkgs.vimPlugins.mini-icons;
        config = ''
          require("mini.icons").setup()
        '';
      };

      miniIndentscope = {
        package = pkgs.vimPlugins.mini-indentscope;
        config = ''
          require("mini.indentscope").setup({
            symbol = "|",
            options = { try_as_border = true },
          })
        '';
      };

      miniPairs = {
        package = pkgs.vimPlugins.mini-pairs;
        config = ''
          require("mini.pairs").setup()
        '';
      };

      miniSurround = {
        package = pkgs.vimPlugins.mini-surround;
        config = ''
          require("mini.surround").setup({
            mappings = {
              add = "gsa",
              delete = "gsd",
              find = "gsf",
              find_left = "gsF",
              highlight = "gsh",
              replace = "gsr",
              update_n_lines = "gsn",
            },
          })
        '';
      };

      miniTrailspace = {
        package = pkgs.vimPlugins.mini-trailspace;
        config = ''
          require("mini.trailspace").setup()
        '';
      };

      noice = {
        package = pkgs.vimPlugins.noice-nvim;
        config = ''
          require("noice").setup({
            lsp = {
              override = {
                ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
                ["vim.lsp.util.stylize_markdown"] = true,
              },
            },
            presets = {
              bottom_search = true,
              command_palette = true,
              long_message_to_split = true,
            },
          })
        '';
      };

      nui = {
        package = pkgs.vimPlugins.nui-nvim;
      };

      nvimLint = {
        package = pkgs.vimPlugins.nvim-lint;
        config = ''
          local lint = require("lint")
          lint.linters_by_ft = {
            bash = { "shellcheck" },
            javascript = { "eslint_d" },
            javascriptreact = { "eslint_d" },
            markdown = { "markdownlint-cli2" },
            nix = { "deadnix", "statix" },
            python = { "ruff" },
            sh = { "shellcheck" },
            typescript = { "eslint_d" },
            typescriptreact = { "eslint_d" },
            yaml = { "yamllint" },
          }
          vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
            callback = function()
              lint.try_lint()
            end,
          })
        '';
      };

      nvimLspconfig = {
        package = pkgs.vimPlugins.nvim-lspconfig;
        config = ''
          local capabilities = require("blink.cmp").get_lsp_capabilities()
          local servers = {
            bashls = {},
            cssls = {},
            docker_compose_language_service = {},
            dockerls = {},
            eslint = {},
            gopls = {
              settings = {
                gopls = {
                  gofumpt = true,
                  staticcheck = true,
                },
              },
            },
            html = {},
            jsonls = {
              settings = {
                json = {
                  schemas = require("schemastore").json.schemas(),
                  validate = { enable = true },
                },
              },
            },
            lua_ls = {
              settings = {
                Lua = {
                  completion = { callSnippet = "Replace" },
                  diagnostics = { globals = { "vim" } },
                  hint = { enable = true },
                  runtime = { version = "LuaJIT" },
                  telemetry = { enable = false },
                  workspace = { checkThirdParty = false },
                },
              },
            },
            marksman = {},
            nixd = {
              settings = {
                nixd = {
                  formatting = { command = { "alejandra" } },
                },
              },
            },
            pyright = {},
            ruff = {},
            rust_analyzer = {},
            taplo = {},
            terraformls = {},
            ts_ls = {},
            yamlls = {
              settings = {
                yaml = {
                  schemaStore = { enable = true },
                  schemas = require("schemastore").yaml.schemas(),
                },
              },
            },
          }

          for name, config in pairs(servers) do
            config.capabilities = capabilities
            vim.lsp.config(name, config)
            vim.lsp.enable(name)
          end

          vim.api.nvim_create_autocmd("LspAttach", {
            callback = function(event)
              local opts = { buffer = event.buf }
              map("n", "gd", vim.lsp.buf.definition, vim.tbl_extend("force", opts, { desc = "Goto definition" }))
              map("n", "gD", vim.lsp.buf.declaration, vim.tbl_extend("force", opts, { desc = "Goto declaration" }))
              map("n", "gr", vim.lsp.buf.references, vim.tbl_extend("force", opts, { desc = "References" }))
              map("n", "gI", vim.lsp.buf.implementation, vim.tbl_extend("force", opts, { desc = "Goto implementation" }))
              map("n", "K", vim.lsp.buf.hover, vim.tbl_extend("force", opts, { desc = "Hover" }))
              map("n", "<leader>ca", vim.lsp.buf.code_action, vim.tbl_extend("force", opts, { desc = "Code action" }))
              map("n", "<leader>cr", vim.lsp.buf.rename, vim.tbl_extend("force", opts, { desc = "Rename" }))
              map("n", "<leader>cl", vim.lsp.codelens.run, vim.tbl_extend("force", opts, { desc = "CodeLens run" }))
            end,
          })
        '';
      };

      nvimNotify = {
        package = pkgs.vimPlugins.nvim-notify;
        config = ''
          require("notify").setup({ timeout = 2500 })
        '';
      };

      nvimTreesitter = let
        parsers = grammars:
          with grammars; [
            bash
            c
            comment
            css
            diff
            dockerfile
            go
            gomod
            gosum
            gowork
            html
            javascript
            json
            lua
            luadoc
            markdown
            markdown_inline
            nix
            python
            regex
            rust
            sql
            toml
            tsx
            typescript
            vim
            vimdoc
            yaml
          ];
      in {
        package = pkgs.vimPlugins.nvim-treesitter.withPlugins parsers;
        config = ''
          require("nvim-treesitter").setup()
          vim.api.nvim_create_autocmd("FileType", {
            pattern = {
              "bash",
              "c",
              "css",
              "diff",
              "dockerfile",
              "go",
              "gomod",
              "gosum",
              "gowork",
              "html",
              "javascript",
              "javascriptreact",
              "json",
              "lua",
              "markdown",
              "nix",
              "python",
              "regex",
              "rust",
              "sql",
              "toml",
              "typescript",
              "typescriptreact",
              "vim",
              "vimdoc",
              "yaml",
            },
            callback = function()
              pcall(vim.treesitter.start)
              vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            end,
          })
        '';
      };

      nvimTreesitterTextobjects = {
        package = pkgs.vimPlugins.nvim-treesitter-textobjects;
        config = ''
          require("nvim-treesitter-textobjects").setup({
            select = {
              lookahead = true,
              keymaps = {
                ["af"] = {
                  query = "@function.outer",
                  desc = "Around function",
                },
                ["if"] = {
                  query = "@function.inner",
                  desc = "Inside function",
                },
                ["ac"] = {
                  query = "@class.outer",
                  desc = "Around class",
                },
                ["ic"] = {
                  query = "@class.inner",
                  desc = "Inside class",
                },
                ["aa"] = {
                  query = "@parameter.outer",
                  desc = "Around argument",
                },
                ["ia"] = {
                  query = "@parameter.inner",
                  desc = "Inside argument",
                },
              },
            },
            move = {
              set_jumps = true,
              goto_next_start = {
                ["]f"] = {
                  query = "@function.outer",
                  desc = "Next function",
                },
                ["]c"] = {
                  query = "@class.outer",
                  desc = "Next class",
                },
              },
              goto_previous_start = {
                ["[f"] = {
                  query = "@function.outer",
                  desc = "Previous function",
                },
                ["[c"] = {
                  query = "@class.outer",
                  desc = "Previous class",
                },
              },
            },
          })
        '';
      };

      nvimTsAutotag = {
        package = pkgs.vimPlugins.nvim-ts-autotag;
        config = ''
          require("nvim-ts-autotag").setup()
        '';
      };

      nvimWebDevicons = {
        package = pkgs.vimPlugins.nvim-web-devicons;
      };

      persistence = {
        package = pkgs.vimPlugins.persistence-nvim;
        config = ''
          require("persistence").setup()
        '';
      };

      plenary = {
        package = pkgs.vimPlugins.plenary-nvim;
      };

      renderMarkdown = {
        package = pkgs.vimPlugins.render-markdown-nvim;
        config = ''
          require("render-markdown").setup({
            file_types = { "markdown", "codecompanion" },
          })
        '';
      };

      snacks = {
        package = pkgs.vimPlugins.snacks-nvim;
        config = ''
          require("snacks").setup({
            bigfile = { enabled = true },
            dashboard = { enabled = false },
            explorer = { enabled = true },
            indent = { enabled = true },
            input = { enabled = true },
            lazygit = { enabled = true },
            notifier = { enabled = true },
            picker = { enabled = true },
            quickfile = { enabled = true },
            scope = { enabled = true },
            scroll = { enabled = true },
            statuscolumn = { enabled = true },
            terminal = { enabled = true },
            words = { enabled = true },
          })

          map("n", "<leader><space>", function()
            Snacks.picker.files()
          end, { desc = "Find files" })
          map("n", "<leader>,", function()
            Snacks.picker.buffers()
          end, { desc = "Buffers" })
          map("n", "<leader>/", function()
            Snacks.picker.grep()
          end, { desc = "Grep" })
          map("n", "<leader>:", function()
            Snacks.picker.command_history()
          end, { desc = "Command history" })
          map("n", "<leader>e", function()
            Snacks.explorer()
          end, { desc = "Explorer" })
          map("n", "<leader>ff", function()
            Snacks.picker.files()
          end, { desc = "Files" })
          map("n", "<leader>fg", function()
            Snacks.picker.git_files()
          end, { desc = "Git files" })
          map("n", "<leader>fr", function()
            Snacks.picker.recent()
          end, { desc = "Recent files" })
          map("n", "<leader>fw", function()
            Snacks.picker.grep_word()
          end, { desc = "Word under cursor" })
          map("n", "<leader>gc", function()
            Snacks.picker.git_log()
          end, { desc = "Git log" })
          map("n", "<leader>gs", function()
            Snacks.picker.git_status()
          end, { desc = "Git status" })
          map("n", "<leader>gg", function()
            Snacks.lazygit()
          end, { desc = "Lazygit" })
          map("n", "<leader>sh", function()
            Snacks.picker.help()
          end, { desc = "Help" })
          map("n", "<leader>sk", function()
            Snacks.picker.keymaps()
          end, { desc = "Keymaps" })
          map("n", "<leader>sc", function()
            Snacks.picker.commands()
          end, { desc = "Commands" })
          map("n", "<leader>sd", function()
            Snacks.picker.diagnostics()
          end, { desc = "Diagnostics" })
          map("n", "<leader>ss", function()
            Snacks.picker.lsp_symbols()
          end, { desc = "Document symbols" })
          map("n", "<leader>sS", function()
            Snacks.picker.lsp_workspace_symbols()
          end, { desc = "Workspace symbols" })
          map("n", "<leader>sn", function()
            Snacks.notifier.show_history()
          end, { desc = "Notification history" })
          map("n", "<leader>z", function()
            Snacks.zen()
          end, { desc = "Zen mode" })
          map("n", "<leader>Z", function()
            Snacks.zen.zoom()
          end, { desc = "Zoom" })
        '';
      };

      todoComments = {
        package = pkgs.vimPlugins.todo-comments-nvim;
        config = ''
          require("todo-comments").setup()
          map("n", "<leader>st", "<cmd>TodoSnacks<cr>", { desc = "Todo comments" })
        '';
      };

      treesj = {
        package = pkgs.vimPlugins.treesj;
        config = ''
          require("treesj").setup({ use_default_keymaps = false })
          map("n", "<leader>cj", require("treesj").toggle, { desc = "Split or join node" })
        '';
      };

      trouble = {
        package = pkgs.vimPlugins.trouble-nvim;
        config = ''
          require("trouble").setup()
          map("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", { desc = "Diagnostics" })
          map("n", "<leader>xX", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", { desc = "Buffer diagnostics" })
          map("n", "<leader>cs", "<cmd>Trouble symbols toggle focus=false<cr>", { desc = "Symbols" })
          map("n", "<leader>cS", "<cmd>Trouble lsp toggle focus=false win.position=right<cr>", { desc = "LSP references" })
        '';
      };

      vimIlluminate = {
        package = pkgs.vimPlugins.vim-illuminate;
        config = ''
          require("illuminate").configure()
        '';
      };

      whichKey = {
        package = pkgs.vimPlugins.which-key-nvim;
        config = ''
          local wk = require("which-key")
          wk.setup({ preset = "modern" })
          wk.add({
            { "<leader>a", group = "ai" },
            { "<leader>b", group = "buffer" },
            { "<leader>c", group = "code" },
            { "<leader>f", group = "find" },
            { "<leader>g", group = "git" },
            { "<leader>gh", group = "hunks" },
            { "<leader>q", group = "quit" },
            { "<leader>s", group = "search" },
            { "<leader>w", group = "write" },
            { "<leader>x", group = "diagnostics" },
          })
          map("n", "<leader>?", function()
            wk.show({ global = false })
          end, { desc = "Buffer keymaps" })
        '';
      };

      yanky = {
        package = pkgs.vimPlugins.yanky-nvim;
        config = ''
          require("yanky").setup()
          map({ "n", "x" }, "p", "<Plug>(YankyPutAfter)", { desc = "Put after" })
          map({ "n", "x" }, "P", "<Plug>(YankyPutBefore)", { desc = "Put before" })
          map("n", "<leader>sy", "<cmd>YankyRingHistory<cr>", { desc = "Yank history" })
        '';
      };
    };

    pluginOrder = [
      "schemaStore"
      "plenary"
      "nui"
      "nvimWebDevicons"
      "miniIcons"
      "catppuccin"
      "friendlySnippets"
      "luasnip"
      "blinkCmp"
      "bufferline"
      "codecompanion"
      "conform"
      "dressing"
      "flash"
      "gitsigns"
      "grugFar"
      "lazydev"
      "lualine"
      "miniAi"
      "miniBufremove"
      "miniComment"
      "miniDiff"
      "miniIndentscope"
      "miniPairs"
      "miniSurround"
      "miniTrailspace"
      "noice"
      "nvimLint"
      "nvimLspconfig"
      "nvimNotify"
      "nvimTreesitter"
      "nvimTreesitterTextobjects"
      "nvimTsAutotag"
      "persistence"
      "renderMarkdown"
      "snacks"
      "todoComments"
      "treesj"
      "trouble"
      "vimIlluminate"
      "whichKey"
      "yanky"
    ];

    enabledPluginSpecs = map (name: pluginSpecs.${name}) (lib.filter isPluginEnabled pluginOrder);
    enabledPluginPackages = map (spec: spec.package) enabledPluginSpecs;
    enabledPluginConfigs = map (spec: spec.config or "") enabledPluginSpecs;
    luaConfig = lib.concatStringsSep "\n\n" (
      [
        sensibleConfig
        baseConfig
      ]
      ++ enabledPluginConfigs
    );

    neovimTools = with pkgs; [
      # Shared runtime for plugins that shell out: CodeCompanion, LSP, Treesitter, and CLIs.
      curl
      gcc
      git
      nodejs
      tree-sitter

      # snacks.nvim picker, explorer, and git UI integrations.
      fd
      lazygit
      ripgrep

      # nvim-lspconfig language servers.
      bash-language-server
      docker-compose-language-service
      dockerfile-language-server
      gopls
      lua-language-server
      marksman
      nil
      nixd
      pyright
      rust-analyzer
      tailwindcss-language-server
      taplo
      terraform-ls
      typescript-language-server
      vscode-langservers-extracted
      yaml-language-server

      # conform.nvim formatters.
      alejandra
      biome
      black
      deno
      gofumpt
      gotools
      prettier
      prettierd
      ruff
      rustfmt
      shfmt
      sqlfluff
      stylua

      # nvim-lint linters.
      deadnix
      eslint_d
      markdownlint-cli2
      shellcheck
      statix
      yamllint

      # Extra code actions and diagnostics helpers.
      ast-grep
      clippy
      codespell
    ];
  in {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      withPython3 = true;
      withRuby = true;

      plugins = enabledPluginPackages;
      extraPackages = neovimTools;
      initLua = luaConfig;
    };

    xdg.configFile."nvim/init.lua" = {
      text = lib.mkDefault "";
      force = true;
    };
  };
}

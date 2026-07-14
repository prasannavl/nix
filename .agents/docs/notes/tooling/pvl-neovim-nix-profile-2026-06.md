# pvl Neovim Nix Profile 2026-06

`users/pvl/neovim/default.nix` owns the simple pvl Neovim profile through Home
Manager. `users/pvl/neovim/dev.nix` owns the development plugin and tool
profile. The dev profile is intentionally Nix-native:

- plugins are declared in `programs.neovim.plugins`;
- LSP servers, formatters, linters, search tools, and AI helper runtime tools
  are declared in `programs.neovim.extraPackages`;
- the Lua config is generated with `programs.neovim.initLua`;
- `lazy.nvim`, LazyVim, Mason, and Mason-managed binary installs are not used.

The dev profile layout is intentionally modular:

- `enabledPlugins` is the central on/off switch set;
- `pluginOrder` preserves deterministic package and config load order;
- `pluginSpecs.<name>.package` owns the Nix plugin package;
- `pluginSpecs.<name>.config` owns that plugin's Lua setup and keymaps;
- plugin-specific Nix inputs, such as Treesitter parser selection, stay inside
  that plugin's `pluginSpecs.<name>` entry;
- `sensibleConfig` owns leader keys, loader setup, and basic keymaps and is
  exported from the simple profile for reuse;
- `baseConfig` owns shared core `vim.opt`, diagnostics, and editor autocmd
  behavior and is exported from the simple profile for reuse;
- `devConfig` owns dev-only options that depend on plugins or richer UI state,
  such as tree-sitter folds and completion menu behavior;
- `neovimTools` owns Mason-replacement language servers, formatters, linters,
  and CLI helpers.

Do not add `pkgs.prettier` back to `neovimTools` just to provide a conform.nvim
fallback. After the July 2026 lockfile update, nixpkgs' `prettier` derivation
forces a dependency path through `pnpm-9.15.9`, which is marked insecure. The
dev profile uses `prettierd` for CSS, HTML, JavaScript, TypeScript, and YAML
formatting instead. JSON formatting keeps `biome` first and `prettierd` second.

When adding or disabling dev editor features, prefer updating those sections
instead of appending more unrelated Lua to `initLua`.

Profile selection is owned by `users/pvl/default.nix`:

- `core` is the regular desktop profile. It imports `./neovim`, the simple
  profile with basic options and keymaps but no plugins or Mason-replacement
  tools;
- `dev` is the full development desktop profile. It imports `./neovim/dev.nix`,
  so `pvl-a1`, `pvl-l5`, and `pvl-x2` get the dev editor;
- `lxc` is the minimal container profile. It imports `./neovim`, matching the
  simple editor profile used by `core`;
- the old public profile names (`desktop-core`, `desktop-gnome-minimal`,
  `desktop-gnome`, and `all`) were removed so consumers choose only `core`,
  `dev`, or `lxc`.

The dev profile avoids the NixOS dynamic-binary boundary that Mason commonly
crosses and keeps plugin and tool versions tied to the flake's pinned package
set. Both profiles keep the existing `xdg.configFile."nvim/init.lua"` fallback
with `lib.mkDefault ""` and `force = true` so Home Manager still owns
`.config/nvim/init.lua` without reintroducing the previous editable-dotfiles
symlink activation failure.

The pinned Neovim is `0.12.3`, and the packaged `nvim-treesitter` is the new
incompatible rewrite. Configure it with:

- `require("nvim-treesitter").setup()`;
- `vim.treesitter.start()` from a `FileType` autocmd for highlighting;
- `vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"` for
  tree-sitter indentation;
- `require("nvim-treesitter-textobjects").setup(...)` for textobjects.

Do not use the older `require("nvim-treesitter.configs").setup(...)` API in the
dev profile.

Dotfiles parity from `~/dotfiles/nvim` that should stay intentional in this
profile:

- wrapping is enabled;
- `tabstop` and `shiftwidth` are `4`, with `softtabstop = -1`;
- `smoothscroll` is explicitly disabled in shared `baseConfig`;
- `whichwrap` lets left/right movement cross line boundaries;
- `<C-Left>`, `<C-Right>`, insert-mode `<C-BS>`, and insert-mode `<C-h>` keep
  the dotfiles word-movement and word-delete behavior;
- `VimEnter` changes the working directory to the opened file's directory when
  there is one;
- `vim.g.snacks_animate = false`;
- `noice.nvim` is not installed or configured;
- `mini.surround` uses the `gsa`/`gsd`/`gsf`/`gsF`/`gsh`/`gsr`/`gsn` mappings;
- `snacks.nvim` dashboard is disabled; the picker, explorer, lazygit, notifier,
  terminal, and other Snacks utility modules stay enabled;
- the profile expects Nerd Font glyph support: the pvl desktop font module makes
  `JetBrainsMono Nerd Font Mono` the fontconfig monospace default, sets GNOME's
  monospace font to the same family, `vim.g.have_nerd_font = true`, and
  `mini.icons` plus `nvim-web-devicons` stay installed so plugin defaults can
  render their normal icons;
- when running on a real TTY without Wayland or X11, `termguicolors` is disabled
  and the default colorscheme is used.

Validation used after the initial profile build:

```sh
nix build --no-link .#nixosConfigurations.pvl-l5.config.home-manager.users.pvl.home.activationPackage
nix build --no-link --print-out-paths .#nixosConfigurations.pvl-l5.config.home-manager.users.pvl.home.activationPackage
```

For a headless Lua smoke test, include the generated Home Manager pack path;
loading only the generated `init.lua` is too bare and will not put Nix-installed
plugins on `packpath`.

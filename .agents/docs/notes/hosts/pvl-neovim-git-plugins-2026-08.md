# Pvl Neovim Git Plugins 2026-08

The `pvl` development Neovim profile declaratively installs Fugitive, Diffview,
gitlogdiff.nvim, git-worktree.nvim, worktrees.nvim, and Neo-tree.

The pinned Nixpkgs plugin set does not provide gitlogdiff.nvim or
worktrees.nvim. Their exact source commits and fixed-output hashes live in
`lib/ext/neovim-plugins/sources.nix`; packaging details live beside them in
`default.nix` and are exposed to consumers as `pkgs.pvl.vimPlugins`.
`users/pvl/neovim/dev.nix` therefore only selects and configures plugins. The
gitlogdiff.nvim build skips the development-only `gitlogdiff.docs` require check
because that module needs Lazy's documentation generator; the runtime modules
remain checked.

`lib/ext/neovim-plugins/update.sh` follows each plugin's declared GitHub branch
to an exact commit, commit date, and fixed-output hash. It updates all custom
plugins discovered from `sources.nix` by default, supports `--plugin NAME` for a
focused refresh, skips prefetching unchanged commits unless `--force` is
requested, and supports the shared `--report` and `--color` interface. Its
executable location makes it automatically discoverable by the repository-level
`scripts/update.sh`; no top-level updater registration is required.

Keep source identity and updater-owned fields in `sources.nix`, build quirks in
`default.nix`, and editor behavior in the user module. When a custom plugin
becomes available in the pinned Nixpkgs plugin set, migrate the consumer to
`pkgs.vimPlugins` and remove its external pin.

Existing dependencies already satisfy the plugins: Diffview and
git-worktree.nvim use Plenary, while Neo-tree uses Plenary and nui.nvim, with
nvim-web-devicons available for icons. Git is already present in the Neovim
runtime tools.

Snacks picker shortcuts follow the existing WhichKey categories:

- `<leader>f` finds navigation targets: buffers, regular and Git files,
  projects, and recent files;
- `<leader>g` covers repository state and history: grep, branches, diff hunks,
  file/log/line history, status, stash, and Lazygit;
- `<leader>s` searches text and editor state: buffer lines, open buffers,
  commands, diagnostics, grep, help, jumps, keymaps, lists, marks, symbols, and
  picker history.

The top-level `<leader><space>`, `<leader>,`, `<leader>/`, `<leader>:`, and
`<leader>e` shortcuts remain direct access to files, buffers, grep, command
history, and the Snacks explorer. Git log uses `<leader>gl`, and word or visual
selection grep uses `<leader>sw`, keeping both operations in their matching
categories instead of the previous `<leader>gc` and `<leader>fw` locations.

Neo-tree remains available through `:Neotree`, gitlogdiff.nvim through
`:GitLogDiff`, git-worktree.nvim through its Lua API, and worktrees.nvim through
`:WorktreeCreate`, `:WorktreeDelete`, and `:WorktreeSwitch`.

Validation:

- `scripts/update.sh --only-ext-neovim-plugins --report --color=never`
- `nix run .#lint -- --base master`
- `nix build --no-link .#nixosConfigurations.pvl-l5.config.home-manager.users.pvl.home.activationPackage`
- A headless Neovim smoke test with `XDG_CONFIG_HOME` and `XDG_DATA_HOME`
  pointed at the activation package's `home-files` verified `:Git`,
  `:DiffviewOpen`, `:GitLogDiff`, `:Neotree`, the `git-worktree` Lua module, and
  all three worktrees.nvim commands.

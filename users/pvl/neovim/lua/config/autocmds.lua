-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here
--

-- VimEnter: Automatically set the cwd to the directory of the current file
local group_cdpwd = vim.api.nvim_create_augroup("group_cdpwd", { clear = true })
vim.api.nvim_create_autocmd("VimEnter", {
    group = group_cdpwd,
    pattern = "*",
    callback = function()
        vim.api.nvim_set_current_dir(vim.fn.expand("%:p:h"))
    end,
})

-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--

local map = vim.keymap.set
local del = vim.keymap.del

-- Ensure Ctrl + Left/Right at beginning/end of line moves to the prev/next
map("n", "<C-Left>", "b", { desc = "Last word" })
map("n", "<C-Right>", "w", { desc = "Next word" })

-- Remap Ctrl + Backspace to delete last word.
-- Note that terminal (not nvim) treats <C-BS> the same as <C-h>, so we map
-- that as well to take effect.
map("i", "<C-BS>", "<C-w>", { desc = "Backspace last word", remap = false })
map("i", "<C-h>", "<C-w>", { desc = "Backspace last word", remap = false })

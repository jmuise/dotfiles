-- Extends LazyVim defaults (lazyvim/config/keymaps.lua has the base set).
local map = vim.keymap.set

-- Stay in visual mode after indenting
map("v", "<", "<gv")
map("v", ">", ">gv")

-- Move selected lines up/down (complements LazyVim's normal-mode <A-j>/<A-k>)
map("v", "J", ":m '>+1<CR>gv=gv", { silent = true })
map("v", "K", ":m '<-2<CR>gv=gv", { silent = true })

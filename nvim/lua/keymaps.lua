-- lua/keymaps.lua

-- Map Tab to Escape in insert and command mode
vim.keymap.set('i', '<Tab>', '<Esc>', { noremap = true, silent = true })
vim.keymap.set('c', '<Tab>', '<Esc>', { noremap = true, silent = true })

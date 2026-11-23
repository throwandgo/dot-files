-- Only deviations from LazyVim's options:
-- https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

vim.g.snacks_animate = false

-- This config predates LazyVim v8, which would otherwise keep fzf-lua and neo-tree. snacks streams
-- rg/zoekt results in-process (fzf-lua pipes every match through a second nvim) and its explorer
-- is the same picker, so neither needs another plugin.
vim.g.lazyvim_picker = "snacks"
vim.g.lazyvim_explorer = "snacks"

-- The root (for <leader>ff, <leader>e, ...) is the git root, never an LSP root: Metals and jdtls
-- roots are build subdirectories of the monorepo.
vim.g.root_spec = { { ".git", "lua" }, "cwd" }

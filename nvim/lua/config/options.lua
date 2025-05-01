-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Disable all animations in Vim.
vim.g.snacks_animate = false

-- Disable showing AI-powered suggestions in the cmp menu.
--
-- The main frustration is that the AI-powered suggestions come back async, and they can end up
-- taking the place of better suggestions from LSP and other sources in the menu. So, instead of
-- showing them in the menu, we instead show them in the virtual text.
vim.g.ai_cmp = false

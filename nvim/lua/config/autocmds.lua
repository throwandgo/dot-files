-- Only additions to LazyVim's autocmds (loaded on VeryLazy).

vim.api.nvim_create_autocmd("FileType", {
  pattern = "gitcommit",
  callback = function()
    vim.opt_local.textwidth = 72
    vim.opt_local.colorcolumn = "73"
  end,
})

require("scala").setup() -- Scala/Java LSP safeguards
require("understand").setup()
require("search.zoekt").setup()

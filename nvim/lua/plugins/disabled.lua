-- LazyVim defaults that earn nothing here.
return {
  { "catppuccin/nvim", enabled = false }, -- tokyonight is the colorscheme
  { "mfussenegger/nvim-lint", enabled = false }, -- only configured linter is fish
  { "rafamadriz/friendly-snippets", enabled = false }, -- generic snippets crowd LSP completions
  { "folke/trouble.nvim", enabled = false }, -- snacks diagnostics/qflist pickers, treesitter-context
  { "MagicDuck/grug-far.nvim", enabled = false }, -- Metals rename covers symbol renames
  { "folke/persistence.nvim", enabled = false },
  {
    "folke/todo-comments.nvim",
    keys = { { "<leader>xt", false }, { "<leader>xT", false } }, -- Trouble views
  },
}

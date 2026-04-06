return {
  -- Syntax highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "proto" } },
  },

  -- Ensure buf is available for formatting
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "buf" } },
  },

  -- LSP: hover, go-to-definition, inline diagnostics
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        buf_ls = {},
      },
    },
  },

  -- Formatter
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        proto = { "buf" },
      },
    },
  },
}

-- Code understanding: hierarchy keymaps (see lua/understand/ for the helpers).
-- treesitter-context and aerial come from LazyVim extras imported in config/lazy.lua.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      -- borderless floats blend into the code behind them
      diagnostics = {
        float = { border = "rounded", source = "if_many" },
        -- Hints (deprecated / unused / "could be async") already render as strikethrough or
        -- faded text; inline messages for them drown out real errors, as in VSCode.
        virtual_text = { severity = { min = vim.diagnostic.severity.INFO } },
      },
      servers = {
        ["*"] = {
          -- stylua: ignore
          keys = {
            { "gap", function() require("understand.hierarchy").pick("supertypes") end, desc = "Supertypes (tree)", has = "prepareTypeHierarchy" },
            { "gac", function() require("understand.hierarchy").pick("subtypes") end, desc = "Subtypes (tree)", has = "prepareTypeHierarchy" },
            { "gau", function() require("understand.hierarchy").super_method() end, desc = "Super Method", has = "definition" },
            { "gr", function() require("understand").references() end, desc = "References", nowait = true },
          },
        },
      },
    },
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = function(_, opts)
      opts.spec = opts.spec or {}
      table.insert(opts.spec, { "ga", group = "navigate", mode = "n" })
    end,
  },
  {
    "stevearc/aerial.nvim",
    optional = true,
    opts = {
      layout = { default_direction = "prefer_right", min_width = 32 },
      -- Follow the cursor so the outline doubles as a "where am I" indicator.
      highlight_on_hover = true,
      autojump = false,
    },
  },
  {
    "nvim-treesitter/nvim-treesitter-context",
    optional = true,
    opts = { max_lines = 4, multiline_threshold = 2, trim_scope = "inner" },
  },
}

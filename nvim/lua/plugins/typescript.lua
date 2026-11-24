-- TypeScript/JavaScript: tsgo + ESLint + prettierd (see lua/typescript/init.lua for the why).
local ts = require("typescript")

local hints_off = { enabled = false }

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- Stays installed in Mason but must never auto-start next to tsgo.
        vtsls = { enabled = false },
        ts_ls = { enabled = false },
        tsgo = {
          mason = false,
          cmd = { ts.tsgo, "--lsp", "--stdio" },
          settings = {
            -- tsgo reads javascript, then typescript, then js/ts; typescript covers both.
            typescript = {
              -- Same policy as Metals: only hints that answer a question while reading. lspconfig's
              -- defaults also label every variable, return, and property type.
              inlayHints = {
                parameterNames = { enabled = "literals", suppressWhenArgumentMatchesName = true },
                parameterTypes = hints_off,
                variableTypes = hints_off,
                propertyDeclarationTypes = hints_off,
                functionLikeReturnTypes = hints_off,
                enumMemberValues = hints_off,
              },
              -- Renaming at a usage of an imported symbol renames the symbol everywhere instead
              -- of aliasing it in the importing file (`import { a as b }`).
              preferences = { useAliasesForRenames = false },
              -- Indentation for edits tsgo writes itself (organize imports, quick fixes). Its
              -- default is 4 spaces, which re-indents multi-line imports until prettier runs.
              format = { indentSize = 2, tabSize = 2, convertTabsToSpaces = true },
            },
          },
          keys = {
            { "<leader>co", ts.organize_imports, desc = "Organize imports" },
          },
        },
        eslint = {
          mason = false,
          cmd = { ts.eslint, "--stdio" },
          -- Typed linting holds a TypeScript program per tsconfig; repos' lint scripts give 8G.
          cmd_env = { NODE_OPTIONS = "--max-old-space-size=8192" },
          handlers = ts.eslint_handlers,
          settings = { format = false }, -- prettier formats; ESLint fixes via ts.eslint_fix
        },
      },
      setup = {
        eslint = function()
          -- Runs before prettier (conform, priority 100); <leader>uf toggles both.
          LazyVim.format.register({
            name = "eslint: fix all",
            primary = false,
            priority = 200,
            format = ts.eslint_fix,
            sources = function(buf)
              return #vim.lsp.get_clients({ bufnr = buf, name = "eslint" }) > 0 and { "eslint" } or {}
            end,
          })
        end,
      },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      for _, ft in ipairs({
        "css",
        "graphql",
        "html",
        "javascript",
        "javascriptreact",
        "json",
        "jsonc",
        "less",
        "markdown",
        "scss",
        "typescript",
        "typescriptreact",
        "yaml",
      }) do
        opts.formatters_by_ft[ft] = { "prettierd" }
      end
      opts.formatters = opts.formatters or {}
      -- Only in repos with a prettier config; elsewhere conform falls back to the LSP formatter.
      opts.formatters.prettierd = { require_cwd = true }
    end,
  },
}

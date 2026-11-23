-- PR review (lua/review/): worktree + tab per PR with a cockpit panel (files with GitHub's Viewed
-- state, agent findings, threads, next step), impact map, threads as diagnostics, pending comments.
-- The interactive agent is sidekick + copilot CLI.
return {
  {
    -- on snacks' spec so these win over its <leader>gi (GitHub issues; still on <leader>gI)
    "folke/snacks.nvim",
    keys = {
      {
        "<leader>gR",
        function()
          require("review").menu()
        end,
        desc = "PR Review (start / panel)",
      },
      {
        "<leader>gC",
        function()
          require("review").comment()
        end,
        desc = "PR Comment (line)",
      },
      {
        "<leader>gC",
        function()
          local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
          vim.cmd.normal({ "\27", bang = true })
          require("review").comment({ math.min(l1, l2), math.max(l1, l2) })
        end,
        mode = "x",
        desc = "PR Comment (lines)",
      },
      {
        "<leader>gi",
        function()
          require("review.impact").open()
        end,
        desc = "Impact of Change (callers)",
      },
    },
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
          require("review").setup()
        end,
      })
    end,
  },
  {
    -- Review tab `d`: side-by-side PR diff. The worktree is at the PR head, so the right side is the
    -- real file (LSP, gd, gitsigns work inside the diff).
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    opts = {
      enhanced_diff_hl = true,
      keymaps = {
        view = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } } },
        file_panel = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
          {
            "n",
            "v",
            function()
              local view = require("diffview.lib").get_current_view()
              local item = view and view.panel:get_item_at_cursor()
              if item and item.path then
                require("review.panel").toggle_viewed(item.path)
              end
            end,
            { desc = "Toggle viewed (PR review)" },
          },
        },
      },
    },
  },
  {
    "folke/sidekick.nvim",
    opts = {
      nes = { enabled = false }, -- edit suggestions aren't the goal; also keeps the copilot LSP off
      cli = {
        context = {
          pr = function()
            return require("review").context()
          end,
        },
        -- stylua: ignore
        prompts = {
          pr_explain = "{pr}\nExplain {this}: what this change does here, why, and what depends on it.",
          pr_impact  = "{pr}\nWhat could this change break? Trace callers and consumers of the changed code (git diff, rg) and list concrete risks with file:line.",
          pr_spec    = "{pr}\nCheck the change against the spec.md invariants for the directories it touches (walk parent: and resolve mixins:). Report violations with file:line.",
          pr_tests   = "{pr}\nWhich behaviour changed here is not covered by tests? List the missing cases.",
        },
      },
    },
  },
}

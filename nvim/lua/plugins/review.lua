-- PR review (lua/review/): worktree + diffview tab per PR with a cockpit panel (files with GitHub's Viewed
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
    opts = {
      indent = {
        -- guides on only one side of a diff break the symmetry and draw over the fold rules
        filter = function(buf, win)
          return vim.g.snacks_indent ~= false
            and vim.b[buf].snacks_indent ~= false
            and vim.bo[buf].buftype == ""
            and not vim.wo[win].diff
        end,
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
    -- The review tab is a diffview of the PR (merge-base -> worktree at the PR head, so the right
    -- side is the real file: LSP, gd, gitsigns work inside the diff).
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    opts = {
      enhanced_diff_hl = true,
      hooks = {
        view_post_layout = function(view)
          require("review.diff_hl").apply(view)
        end,
      },
      keymaps = {
        view = {
          {
            "n",
            "q",
            function()
              local st = require("review").active()
              if st and st.tab == vim.api.nvim_get_current_tabpage() then
                require("review.panel").confirm_close()
              else
                vim.cmd.DiffviewClose()
              end
            end,
            { desc = "Close diffview / end review" },
          },
        },
        file_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } } },
      },
    },
  },
  {
    "folke/sidekick.nvim",
    opts = {
      nes = { enabled = false }, -- edit suggestions aren't the goal; also keeps the copilot LSP off
      cli = {
        win = {
          keys = {
            -- <space> is typed into the CLI and herdr doesn't pass <c-.>, so <c-q> (the CLI's own
            -- ctrl+q was already shadowed by sidekick) collapses the panel; <c-\><c-n> for normal mode
            stopinsert = false,
            hide_t = { "<c-q>", "hide", mode = "t", desc = "hide the terminal window" },
          },
        },
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

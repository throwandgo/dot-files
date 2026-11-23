-- Homepage (lua/review/home.lua): my PRs, reviews waiting on me, a plain agent session, and the
-- few launchers worth keeping. <leader>h brings it back.
local function home()
  return require("review.home")
end

return {
  {
    "folke/snacks.nvim",
    keys = {
      {
        "<leader>h",
        function()
          home().open()
        end,
        desc = "Homepage",
      },
    },
    opts = function(_, opts)
      local pick = opts.dashboard and opts.dashboard.preset and opts.dashboard.preset.pick
      opts.dashboard = {
        width = 100,
        preset = {
          pick = pick,
          -- stylua: ignore
          keys = {
            { icon = " ", key = "a", desc = "Agent session (copilot)", action = function() home().agent() end },
            { icon = " ", key = "f", desc = "Find file", action = ":lua Snacks.dashboard.pick('files')" },
            { icon = " ", key = "g", desc = "Grep repo", action = function() require("search.zoekt").grep() end },
            { icon = " ", key = "o", desc = "Recent files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
            { icon = " ", key = "s", desc = "Restore session", section = "session" },
            { icon = " ", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
        sections = {
          function()
            return home().mine()
          end,
          function()
            return home().reviews()
          end,
          { section = "keys", padding = 1 },
          { section = "startup" },
        },
      }
    end,
  },
}

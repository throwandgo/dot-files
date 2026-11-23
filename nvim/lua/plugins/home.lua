-- Homepage (lua/review/home.lua): a roadrunner, launchers for my PRs, reviews waiting on me and a
-- plain agent session, and the few file launchers worth keeping. <leader>h brings it back.
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
        width = 72,
        preset = {
          pick = pick,
          header = home().LOGO,
          -- stylua: ignore
          keys = {
            { icon = " ", key = "f", desc = "Find file", action = ":lua Snacks.dashboard.pick('files')" },
            { icon = " ", key = "g", desc = "Grep repo", action = function() require("search.zoekt").grep() end },
            { icon = " ", key = "o", desc = "Recent files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
            { icon = " ", key = "s", desc = "Restore session", section = "session" },
            { icon = " ", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
        sections = {
          { section = "header" },
          function()
            return home().launchers()
          end,
          { section = "keys", padding = 1 },
          { section = "startup" },
        },
      }
    end,
  },
}

-- Indexed grep and repo-wide symbols via zoekt (lua/search/zoekt.lua, home/zoekt.nix).
local function zoekt()
  return require("search.zoekt")
end

return {
  {
    "folke/snacks.nvim",
    -- stylua: ignore
    keys = {
      { "<leader>/", function() zoekt().grep() end, desc = "Grep (repo, indexed)" },
      { "<leader>sg", function() zoekt().grep() end, desc = "Grep (repo, indexed)" },
      { "<leader>sw", function() zoekt().grep_word() end, desc = "Word/Selection (repo, indexed)", mode = { "n", "x" } },
      { "<leader>sS", function() zoekt().symbols() end, desc = "Symbols (repo, indexed)" },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      -- LSP workspace symbols only cover one build; <leader>sS above covers the repo
      servers = { ["*"] = { keys = { { "<leader>sS", false } } } },
    },
  },
}

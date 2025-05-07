-- Git utilities in Vim.

local cond = require("utils.conditions")

return {
  "tpope/vim-fugitive",
  cond = cond.is_in_git_repo,
}

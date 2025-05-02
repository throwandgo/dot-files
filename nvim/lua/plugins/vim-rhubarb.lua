-- Used for GitHub integration with vim-fugitive.
--
-- Examples:
-- 1. :GBrowse to open one or more lines in GitHub
-- 2. <C-X><C-O> for omni-completion in commit messages (e.g. for GitHub issues)

local cond = require("utils.conditions")

return {
  {
    "tpope/vim-rhubarb",
    cond = cond.is_in_git_repo,
  },
}

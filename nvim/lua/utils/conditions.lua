local M = {}

function M.is_in_git_repo()
  local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
  if not handle then
    return false
  end

  local result = handle:read("*a")
  handle:close()
  return result and result:match("true") ~= nil
end

return M

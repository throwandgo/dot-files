local M = {}

function M.check()
  vim.health.start("review tools")
  if vim.fn.executable("gh") ~= 1 then
    vim.health.error("gh not found; PR review needs the GitHub CLI")
  else
    local auth = vim.system({ "gh", "auth", "status", "--active" }, { text = true }):wait()
    if auth.code == 0 then
      vim.health.ok("gh authenticated")
    else
      vim.health.error("gh not authenticated", { "gh auth login" })
    end
  end
  if vim.fn.executable("copilot") == 1 then
    vim.health.ok("copilot CLI found (agent pre-pass and sidekick)")
  else
    vim.health.warn("copilot CLI not found; agent review is skipped")
  end

  vim.health.start("review worktree")
  local root = vim.fs.joinpath(vim.fn.stdpath("cache"), "review")
  local found = false
  for name, kind in vim.fs.dir(root) do
    local wt = vim.fs.joinpath(root, name)
    if kind == "directory" and vim.uv.fs_stat(vim.fs.joinpath(wt, ".git")) then
      found = true
      local dirty = vim
        .system({ "git", "status", "--porcelain", "--untracked-files=no" }, { cwd = wt, text = true })
        :wait()
      if dirty.code ~= 0 then
        vim.health.warn(wt .. ": not a valid worktree", { "rm -rf " .. wt .. " && git worktree prune" })
      elseif vim.trim(dirty.stdout) ~= "" then
        vim.health.warn(wt .. ": has local edits (the next review asks before discarding them)")
      else
        vim.health.ok(wt)
      end
    end
  end
  if not found then
    vim.health.info("none yet; created on the first :Review")
  end
end

return M

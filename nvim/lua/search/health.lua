local M = {}

function M.check()
  local z = require("search.zoekt")
  vim.health.start("zoekt server")
  local err, status, list = z.post_sync("/api/list", { Q = "" }, 2000)
  if err or status ~= 200 or not list then
    vim.health.error(
      ("zoekt unreachable at %s: %s"):format(z.url(), err or status),
      { "launchctl kickstart -k gui/$(id -u)/org.nix-community.home.zoekt-webserver", "~/Library/Logs/zoekt-*.log" }
    )
    vim.health.info("grep falls back to rg (~0.5s per query)")
    return
  end
  vim.health.ok("listening on " .. z.url())
  for _, r in ipairs(vim.tbl_get(list, "List", "Repos") or {}) do
    local repo, sha = r.Repository, r.Repository.Branches[1].Version
    local behind = vim.system({ "git", "-C", repo.Source, "rev-list", "--count", sha .. "..HEAD" }):wait()
    local msg = ("%s @ %s (%d files)"):format(repo.Source, sha:sub(1, 8), r.Stats and r.Stats.Documents or 0)
    if behind.code ~= 0 then
      vim.health.warn(msg .. ": indexed commit not found")
    elseif tonumber(behind.stdout) > 0 then
      vim.health.warn(
        ("%s: %d commits behind HEAD"):format(msg, tonumber(behind.stdout)),
        { "launchctl kickstart gui/$(id -u)/org.nix-community.home.zoekt-index" }
      )
    else
      vim.health.ok(msg)
    end
  end

  vim.health.start("zoekt overlay for cwd")
  local state = z.root(vim.uv.cwd())
  if not state then
    vim.health.info("cwd is not in a git repository")
    return
  end
  z.refresh(state)
  vim.wait(5000, function()
    return state.ready and not state.refreshing
  end, 10)
  if state.fallback then
    vim.health.warn(state.root .. ": using rg: " .. state.fallback)
  else
    vim.health.ok(("%s: %d files searched with rg instead of the index"):format(state.root, #state.files))
  end
end

return M

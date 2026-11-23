-- Keeps each Metals workspace on a working Bloop build without manual commands.
--
-- Bloop over the sbt server: it compiles faster and runs apart from a terminal `sbt run`, which
-- the sbt server shares, so Metals' compiles would queue behind the running app.
--   * Metals' "which build server?" prompt is answered with Bloop.
--   * A workspace Metals connected to the sbt server (a choice it persists) is switched to Bloop.
--   * Metals skips importing an unchanged build whatever its last import did, so an import that
--     failed or was interrupted (nvim quit mid-import) leaves the workspace without build targets.
--     Those, and a Bloop export that has gone missing, are re-imported once per session.
local guards = require("scala.guards")

local M = {}

local BSP_PROMPT = "Multiple build servers detected, which one do you want to use?"

local function info(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.INFO, { title = "Metals" })
  end)
end

-- Answer for a window/showMessageRequest, or nil to show it to the user.
---@return lsp.MessageActionItem?
function M.answer(params)
  if params.message ~= BSP_PROMPT then
    return nil
  end
  for _, action in ipairs(params.actions or {}) do
    if action.title:lower():match("^bloop") then
      return action
    end
  end
end

local function exec(client, command)
  client:request("workspace/executeCommand", { command = command }, function() end)
end

-- Calls on_line for each line Metals appends to its log until it returns true or timeout_ms passes.
local function follow_log(root, timeout_ms, on_line)
  local path = root .. "/.metals/metals.log"
  local offset = vim.fn.getfsize(path)
  local deadline = vim.uv.now() + timeout_ms
  local timer = assert(vim.uv.new_timer())
  local function stop()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      local size = vim.fn.getfsize(path)
      if size < offset then
        offset = 0 -- rotated
      end
      if size > offset then
        local f = io.open(path, "r")
        if f then
          f:seek("set", offset)
          local chunk = f:read("*a")
          f:close()
          offset = size
          for line in chunk:gmatch("[^\n]+") do
            if on_line((line:gsub("\27%[[%d;]*m", ""))) then
              return stop()
            end
          end
        end
      end
      if vim.uv.now() > deadline then
        stop()
      end
    end)
  )
end

-- Bloop project files exported by the last import (.bloop/bloop.settings.json is not one).
local function has_bloop_export(root)
  for _, f in ipairs(vim.fn.glob(root .. "/.bloop/*.json", false, true)) do
    if vim.fs.basename(f) ~= "bloop.settings.json" then
      return true
    end
  end
  return false
end

--- Why the workspace needs an import Metals won't start on its own, if it does.
---@param st scala.Import?
function M.import_reason(root, st)
  if not (st and st.skipped) then
    return nil
  end
  if st.skipped == "Failed" then
    return "the last one failed"
  elseif st.skipped == "Started" then
    return "the last one was interrupted"
  elseif st.skipped ~= "Installed" then
    return ("its status is %s"):format(st.skipped)
  elseif vim.uv.fs_stat(root .. "/build.sbt") and not has_bloop_export(root) then
    return "the Bloop export is missing"
  end
end

local seen, imported = {}, {}

local function import(client, root, why)
  if imported[root] or client:is_stopped() then
    return
  end
  imported[root] = true
  info(("Importing the build at %s (%s)"):format(vim.fn.fnamemodify(root, ":~"), why))
  exec(client, "metals.build-import")
end

---@param client vim.lsp.Client
function M.on_attach(client)
  local root = client.root_dir
  if not root or seen[root] then
    return
  end
  seen[root] = true

  vim.defer_fn(function()
    local why = M.import_reason(root, guards.last_import(root))
    if why then
      import(client, root, why)
    end
  end, 3000)

  local switched = false
  follow_log(root, 180000, function(line)
    local server = line:match("Connected to Build server: (%S+)")
    if server == "sbt" and not switched and not client:is_stopped() then
      switched = true
      info(("Switching %s from the sbt server to Bloop"):format(vim.fn.fnamemodify(root, ":~")))
      exec(client, "metals.bsp-switch")
    elseif server == "Bloop" then
      if not has_bloop_export(root) then
        import(client, root, "Bloop has no export yet")
      end
      return true
    end
    return false
  end)
end

return M

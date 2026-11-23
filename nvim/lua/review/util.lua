-- Tiny coroutine helpers so the review flow reads top-to-bottom instead of as nested callbacks.
local M = {}

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Review" })
end

--- Run `fn` as a coroutine; errors become notifications.
function M.run(fn)
  coroutine.wrap(function()
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
      -- user-facing message: no traceback, no "init.lua:427: " position prefix
      local msg = tostring(err):gsub("\nstack traceback:.*", ""):gsub("^[^\n]-%.lua:%d+: ", "")
      M.notify(msg, vim.log.levels.ERROR)
    end
  end)()
end

--- Call callback-style `f(..., cb)` and yield until `cb` fires. The resume is always scheduled, so a
--- synchronous callback can't resume a running coroutine.
function M.await(f, ...)
  local co = assert(coroutine.running(), "await outside util.run")
  local args, n = { ... }, select("#", ...)
  args[n + 1] = function(...)
    local res, rn = { ... }, select("#", ...)
    vim.schedule(function()
      local ok, err = coroutine.resume(co, unpack(res, 1, rn))
      if not ok then
        M.notify(tostring(err), vim.log.levels.ERROR)
      end
    end)
  end
  f(unpack(args, 1, n + 1))
  return coroutine.yield()
end

--- Run a command; returns trimmed stdout or raises with stderr.
---@param cmd string[]
---@param opts? vim.SystemOpts
function M.sh(cmd, opts)
  local r = M.await(function(cb)
    vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {}), cb)
  end)
  if r.code ~= 0 then
    local err = vim.trim(r.stderr or "")
    error(("%s: %s"):format(table.concat(cmd, " ", 1, math.min(#cmd, 4)), err ~= "" and err or ("exit " .. r.code)), 0)
  end
  return vim.trim(r.stdout or "")
end

function M.input(opts)
  return M.await(vim.ui.input, opts)
end

function M.select(items, opts)
  return M.await(vim.ui.select, items, opts)
end

return M

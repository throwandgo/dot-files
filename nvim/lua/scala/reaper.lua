-- Stops JVM language servers whose files haven't been visible for a while. Each Metals holds up
-- to 6 GB, and a day of hopping between builds otherwise leaves a dozen of them running.
-- Servers come back when you return to one of their files; Metals' index and Bloop's compile
-- state live on disk, so a restart is quick.
local M = {}

M.names = { "metals", "jdtls" }
M.interval_ms = 60 * 1000

---@type { name: string, root: string, at: integer }[]
M.reaped = {}

local hidden_since = {} ---@type table<integer, integer>

---@return integer minutes, 0 when disabled
function M.minutes()
  return tonumber(vim.g.lsp_reaper_minutes) or 20
end

local function visible(client)
  for _, buf in ipairs(vim.lsp.get_buffers_by_client_id(client.id)) do
    if #vim.fn.win_findbuf(buf) > 0 then
      return true
    end
  end
  return false
end

---@param client vim.lsp.Client
function M.reap(client)
  for _, buf in ipairs(vim.lsp.get_buffers_by_client_id(client.id)) do
    vim.b[buf].lsp_reaped = client.name
  end
  table.insert(M.reaped, { name = client.name, root = client.root_dir or "?", at = os.time() })
  hidden_since[client.id] = nil
  client:stop()
  vim.notify(
    ("Stopped idle %s for %s (no file visible for %d min). It restarts when you open one of its files."):format(
      client.name,
      vim.fn.fnamemodify(client.root_dir or "?", ":~"),
      M.minutes()
    ),
    vim.log.levels.INFO,
    { title = "LSP reaper" }
  )
end

---@param now? integer ms
function M.tick(now)
  local minutes = M.minutes()
  if minutes <= 0 then
    return
  end
  now = now or vim.uv.now()
  for _, client in ipairs(vim.lsp.get_clients()) do
    if vim.tbl_contains(M.names, client.name) and not client:is_stopped() then
      if visible(client) then
        hidden_since[client.id] = nil
      else
        hidden_since[client.id] = hidden_since[client.id] or now
        if now - hidden_since[client.id] >= minutes * 60 * 1000 then
          M.reap(client)
        end
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("lsp_reaper", { clear = true })
  -- Re-runs the FileType hooks that start the server (nvim-metals' group, LazyVim's jdtls one).
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local name = vim.b[ev.buf].lsp_reaped
      if not name or #vim.lsp.get_clients({ bufnr = ev.buf, name = name }) > 0 then
        return
      end
      vim.b[ev.buf].lsp_reaped = nil
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          vim.api.nvim_exec_autocmds("FileType", {
            group = name == "metals" and "nvim-metals" or nil,
            buffer = ev.buf,
            modeline = false,
          })
        end
      end)
    end,
  })
  if M.timer then
    M.timer:stop()
  end
  M.timer = assert(vim.uv.new_timer())
  M.timer:start(M.interval_ms, M.interval_ms, vim.schedule_wrap(M.tick))
end

return M

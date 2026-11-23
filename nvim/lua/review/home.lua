-- Homepage (snacks dashboard): your open PRs, PRs waiting on your review, and a plain agent session.
-- Rows draw from a disk cache so the page is instant; a background refresh repaints it when stale.
local inbox = require("review.inbox")
local util = require("review.util")

local M = {}

local CACHE = vim.fs.joinpath(vim.fn.stdpath("cache"), "review", "home.json")
local STALE = 60 -- seconds
local MAX_ROWS = { mine = 8, reviews = 5 }
local WIDTH = 100

---@type { mine?: table[], mine_count?: integer, reviews?: { you: integer, team: integer, top: table[] }, at?: integer, error?: string }
M.data = {}
local loading = false

local function load()
  local f = io.open(CACHE)
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
    f:close()
    M.data = ok and type(data) == "table" and data or {}
  end
end
load()

local function save()
  vim.fn.mkdir(vim.fs.dirname(CACHE), "p")
  local f = io.open(CACHE, "w")
  if f then
    f:write(vim.json.encode(M.data))
    f:close()
  end
end

local function slim(item)
  local keep = {}
  for _, k in ipairs({ "label", "repo", "number", "title", "url", "author", "updated", "ci", "decision" }) do
    keep[k] = item[k]
  end
  for _, k in ipairs({ "draft", "conflicts", "unresolved" }) do
    keep[k] = item[k]
  end
  return keep
end

--- Re-fetch both lists (in parallel) unless fresh or already loading; repaints when done.
function M.refresh(force)
  if loading or (not force and M.data.at and os.time() - M.data.at < STALE) then
    return
  end
  loading = true
  local pending, err = 2, nil
  local function done()
    pending = pending - 1
    if pending == 0 then
      loading = false
      M.data.at = os.time()
      M.data.error = err
      save()
      Snacks.dashboard.update()
    end
  end
  local function job(fn)
    util.run(function()
      local ok, e = pcall(fn)
      if not ok then
        err = tostring(e)
      end
      done()
    end)
  end
  job(function()
    local q = vim.tbl_extend("force", inbox.mine_query, { first = MAX_ROWS.mine })
    local items, counts = inbox.search({ q })
    M.data.mine, M.data.mine_count = vim.tbl_map(slim, items), counts[1]
  end)
  job(function()
    local r = inbox.summary(MAX_ROWS.reviews)
    r.top = vim.tbl_map(slim, r.top)
    M.data.reviews = r
  end)
end

local function short_repo(item)
  return item.repo:match("/(.+)$")
end

local function fit(s, n)
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

local function width_of(chunks)
  local w = 0
  for _, c in ipairs(chunks) do
    w = w + vim.api.nvim_strwidth(c[1])
  end
  return w
end

--- Column widths shared by a section's rows, so titles line up.
local function columns(items, with_author)
  local w = { repo = 0, status = 0, author = with_author and 0 or nil }
  for _, item in ipairs(items) do
    if with_author then
      w.author = math.max(w.author, vim.api.nvim_strwidth(fit("@" .. item.author, 20)))
    end
    w.repo = math.max(w.repo, vim.api.nvim_strwidth(fit(short_repo(item), 16) .. " #" .. item.number))
    w.status = math.max(w.status, width_of(inbox.status(item)))
  end
  return w
end

--- One dashboard row: age, repo #n, status, title (trimmed so the row fits).
local function row(item, w)
  local status = inbox.status(item)
  local repo = fit(short_repo(item), 16) .. " #" .. item.number
  local head = {
    { ("%-4s"):format(inbox.ago(item.updated)), "Comment" },
    { repo .. (" "):rep(w.repo - vim.api.nvim_strwidth(repo) + 1), "Comment" },
  }
  vim.list_extend(head, status)
  head[#head + 1] = { (" "):rep(w.status - width_of(status) + 2) }
  if w.author then
    local who = fit("@" .. item.author, 20)
    head[#head + 1] = { who .. (" "):rep(w.author - vim.api.nvim_strwidth(who) + 2), "Special" }
  end
  local room = WIDTH - 8 - width_of(head)
  head[#head + 1] = { fit(item.title, math.max(room, 10)) }
  return {
    desc = head,
    autokey = true,
    action = function()
      require("review").start(item.url)
    end,
  }
end

local function note(text, hl)
  return { desc = { { text, hl or "Comment" } } }
end

local function status_note(rows)
  if #rows > 0 then
    return rows
  end
  if M.data.error then
    return { note(M.data.error, "DiagnosticError") }
  end
  return { note(loading and "loading…" or "nothing here") }
end

--- Dashboard section: your open PRs, most recently updated first.
function M.mine()
  M.refresh()
  local shown = vim.list_slice(M.data.mine or {}, 1, MAX_ROWS.mine)
  local w, rows = columns(shown), {}
  for _, item in ipairs(shown) do
    rows[#rows + 1] = row(item, w)
  end
  local n = M.data.mine_count or #(M.data.mine or {})
  return {
    title = "My PRs" .. (n > MAX_ROWS.mine and (" · %d open"):format(n) or ""),
    icon = " ",
    key = "p",
    action = inbox.open_mine,
    padding = 1,
    indent = 2,
    status_note(rows),
  }
end

--- Dashboard section: PRs waiting on your review (direct asks listed; the team queue counted).
function M.reviews()
  local r = M.data.reviews
  local shown = r and r.top or {}
  local w, rows = columns(shown, true), {}
  for _, item in ipairs(shown) do
    rows[#rows + 1] = row(item, w)
  end
  local title = "Reviews waiting"
  if r then
    title = ("%s · %d for you · %d more for LNE"):format(title, r.you, r.team)
  end
  return {
    title = title,
    icon = " ",
    key = "r",
    action = inbox.open,
    padding = 1,
    indent = 2,
    status_note(rows),
  }
end

--- Show the homepage without clobbering work: jump to a tab already showing it, else use the
--- current window only if it holds an empty scratch buffer, else open a new tab.
function M.open()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_dashboard" then
      vim.api.nvim_set_current_win(win)
      M.refresh()
      return
    end
  end
  local buf = vim.api.nvim_get_current_buf()
  local blank = vim.api.nvim_buf_get_name(buf) == ""
    and vim.bo[buf].buftype == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  if not blank then
    vim.cmd.tabnew()
  end
  Snacks.dashboard()
end

--- Plain copilot CLI session (no PR context).
function M.agent()
  require("sidekick.cli").show({ name = "copilot", focus = true })
end

M.WIDTH = WIDTH

return M

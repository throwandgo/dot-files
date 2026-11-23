-- Review cockpit: a sidebar in the review tab (a diffview of the PR) with what's left to do, where everything is, and the
-- keys to get there. Files carry GitHub's "Viewed" state (synced both ways), agent findings and
-- threads link to their lines, and the top line always names the next step.
local gh = require("review.gh")
local util = require("review.util")

local M = {}

local ns = vim.api.nvim_create_namespace("review.panel")
local NAME = "review://panel"
local WIDTH = 50

---@class review.Item
---@field kind "header"|"next"|"files"|"file"|"agent"|"finding"|"threads"|"thread"
---@field path? string
---@field lnum? integer
---@field detail? string
---@field run? fun()

---@type table<integer, review.Item>
local items = {}

for name, link in pairs({
  ReviewTitle = "Title",
  ReviewDim = "Comment",
  ReviewSection = "Function",
  ReviewGroup = "Type",
  ReviewNext = "DiagnosticOk",
  ReviewViewed = "DiagnosticOk",
  ReviewUnviewed = "DiagnosticWarn",
  ReviewCurrent = "CursorLineNr",
  ReviewAdd = "Added",
  ReviewDel = "Removed",
  ReviewKey = "Special",
  ReviewBug = "DiagnosticWarn",
  ReviewRisk = "DiagnosticInfo",
  ReviewQuestion = "DiagnosticHint",
  ReviewFail = "DiagnosticError",
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

local function review()
  return require("review")
end

local function buf()
  -- bufnr() would treat the name as a file pattern
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == NAME then
      return b
    end
  end
end

local function win(st)
  local b = buf()
  for _, w in ipairs(b and vim.api.nvim_tabpage_list_wins(st.tab) or {}) do
    if vim.api.nvim_win_get_buf(w) == b then
      return w
    end
  end
end

--- The review's diffview (its tab is the review tab).
local function view(st)
  local ok, lib = pcall(require, "diffview.lib")
  for _, v in ipairs(ok and lib.views or {}) do
    if v.tabpage == st.tab then
      return v
    end
  end
end

--- Right side of the diff: the worktree file, at the PR head (LSP, gd, gitsigns work there).
local function main_win(st)
  local v = view(st)
  local w = v and v.cur_layout and v.cur_layout:get_main_win()
  return w and w.id and vim.api.nvim_win_is_valid(w.id) and w.id or nil
end

local function current_path(st)
  local v = view(st)
  return v and v.panel.cur_file and v.panel.cur_file.path
end

--- Open the PR diff (merge-base → worktree) in a new tab, which becomes the review tab. The panel
--- replaces diffview's own file list.
function M.open_view(st, path)
  vim.cmd(
    ("DiffviewOpen %s -C%s --selected-file=%s"):format(
      st.merge_base,
      vim.fn.fnameescape(st.root),
      vim.fn.fnameescape(vim.fs.joinpath(st.root, path or st.files[1]))
    )
  )
  local v = require("diffview.lib").get_current_view()
  st.tab = v.tabpage
  vim.t[st.tab].review = st.number
  vim.cmd.tcd(vim.fn.fnameescape(st.root))
  v.panel:close()
end

--- Show `path` (repo-relative) in the diff, at `lnum` or its first change.
function M.open(path, lnum)
  local st = review().active()
  if not st then
    return
  end
  local v = view(st)
  if not v then
    M.open_view(st, path)
    v = view(st)
  else
    vim.api.nvim_set_current_tabpage(st.tab)
    v:set_file_by_path(path, true)
  end
  lnum = lnum or (st.hunks[path] or {})[1] or 1
  local file = vim.fs.joinpath(st.root, path)
  -- set_file is async: place the cursor once the worktree file is in the main window
  local tries = 0
  local function place()
    local w = main_win(st)
    if w and current_path(st) == path and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == file then
      vim.api.nvim_set_current_win(w)
      vim.cmd("wincmd =") -- the panel keeps its width; the two sides split the rest evenly
      pcall(vim.api.nvim_win_set_cursor, w, { math.min(lnum, vim.api.nvim_buf_line_count(0)), 0 })
      vim.cmd("normal! zz")
    elseif tries < 100 and (st.stats[path] or {}).status ~= "D" then
      tries = tries + 1
      vim.defer_fn(place, 20)
    end
  end
  place()
end

--- Next (or previous) changed file after `from`; with `unviewed`, skips viewed ones.
function M.next_file(st, from, step, unviewed)
  local n = #st.files
  local idx = from and vim.fn.index(st.files, from) + 1 or 0
  for i = 1, n do
    local f = st.files[(idx - 1 + step * i) % n + 1]
    if not unviewed or not st.viewed[f] then
      return f
    end
  end
end

function M.jump(step)
  local st = review().active()
  local f = st and M.next_file(st, current_path(st) or review().relpath(0), step)
  if f then
    M.open(f)
  end
end

function M.toggle_viewed(path)
  local st = review().active()
  if not (st and path) then
    return
  end
  local viewed = not st.viewed[path]
  st.viewed[path] = viewed
  M.render()
  util.run(function()
    local ok, err = pcall(gh.graphql, viewed and gh.MARK_VIEWED or gh.UNMARK_VIEWED, {
      input = { pullRequestId = st.id, path = path },
    })
    if not ok then
      st.viewed[path] = not viewed
      M.render()
      error(err, 0)
    end
  end)
end

function M.submit()
  util.run(function()
    local choice = util.select({ "Approve", "Request changes", "Comment" }, { prompt = "Submit review" })
    if choice then
      review().submit(({ Approve = "APPROVE", ["Request changes"] = "REQUEST_CHANGES", Comment = "COMMENT" })[choice])
    end
  end)
end

local function pending(st)
  return #vim.tbl_filter(function(t)
    local c = t.comments and t.comments.nodes and t.comments.nodes[1]
    return c and c.state == "PENDING"
  end, st.threads or {})
end

---@return string, fun()
local function next_step(st)
  local f = M.next_file(st, current_path(st), 1, true)
  if f then
    local left = #vim.tbl_filter(function(p)
      return not st.viewed[p]
    end, st.files)
    return ("n  next unviewed: %s (%d left)"):format(vim.fs.basename(f), left), function()
      M.open(f)
    end, f
  end
  local p = pending(st)
  if p > 0 then
    return ("s  all viewed: submit with %d pending comment%s"):format(p, p == 1 and "" or "s"), M.submit
  end
  return "s  all viewed: approve or request changes", M.submit
end

local CI = {
  SUCCESS = { "✓ CI passing", "ReviewViewed" },
  FAILURE = { "✗ CI failing", "ReviewFail" },
  ERROR = { "✗ CI error", "ReviewFail" },
  PENDING = { "● CI running", "ReviewUnviewed" },
  EXPECTED = { "● CI waiting", "ReviewUnviewed" },
}
local DECISION = {
  APPROVED = { "approved", "ReviewViewed" },
  CHANGES_REQUESTED = { "changes requested", "ReviewFail" },
  REVIEW_REQUIRED = { "review required", "ReviewDim" },
}
local KIND_HL = { bug = "ReviewBug", risk = "ReviewRisk", question = "ReviewQuestion" }

local function oneline(s, max)
  s = vim.trim((s or ""):gsub("%s+", " "))
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

local function counts(st, path)
  local f, t = 0, 0
  for _, x in ipairs(st.findings or {}) do
    f = f + (x.path == path and 1 or 0)
  end
  for _, x in ipairs(st.threads or {}) do
    t = t + (x.path == path and not x.isResolved and 1 or 0)
  end
  return f, t
end

function M.render()
  local st, b = review().active(), buf()
  if not (st and b) then
    return
  end
  local lines, hls = {}, {}
  items = {}
  local function add(chunks, item)
    local line = ""
    for _, c in ipairs(chunks) do
      if c[2] then
        hls[#hls + 1] = { #lines, #line, #line + #c[1], c[2] }
      end
      line = line .. c[1]
    end
    lines[#lines + 1] = line
    items[#lines] = item
  end
  local header = { kind = "header" }

  add({ { ("#%d "):format(st.number), "ReviewKey" }, { st.title, "ReviewTitle" } }, header)
  local ci, dec = CI[st.ci or ""], DECISION[st.decision or ""]
  add({
    { "@" .. st.author, "ReviewSection" },
    { " → " .. st.base_ref, "ReviewDim" },
    { ci and "  " or "" },
    ci or { "" },
    { dec and " · " or "", "ReviewDim" },
    dec or { "" },
  }, header)
  add({})
  local text, run, next_path = next_step(st)
  add({ { "▶ ", "ReviewNext" }, { text, "ReviewNext" } }, { kind = "next", run = run, path = next_path })
  add({})

  local cur = current_path(st)
  local viewed = #vim.tbl_filter(function(p)
    return st.viewed[p]
  end, st.files)
  add(
    { { "Files ", "ReviewSection" }, { ("%d/%d viewed"):format(viewed, #st.files), "ReviewDim" } },
    { kind = "files" }
  )
  local ok_icons, icons = pcall(require, "mini.icons")
  local rank = require("review.rank")
  local group
  for _, path in ipairs(st.files) do
    local g = rank.group(path)
    if g ~= group then
      group = g
      local in_group = vim.tbl_filter(function(p)
        return rank.group(p) == g
      end, st.files)
      local done = #vim.tbl_filter(function(p)
        return st.viewed[p]
      end, in_group)
      add({ { " " .. rank.GROUPS[g] .. " ", "ReviewGroup" }, { ("%d/%d"):format(done, #in_group), "ReviewDim" } }, {
        kind = "group",
      })
    end
    local s = st.stats[path] or {}
    local icon, icon_hl = "", nil
    if ok_icons then
      icon, icon_hl = icons.get("file", path)
      icon = icon .. " "
    end
    local nf, nt = counts(st, path)
    add({
      { path == cur and "▸" or " ", "ReviewCurrent" },
      { st.viewed[path] and "✓ " or "· ", st.viewed[path] and "ReviewViewed" or "ReviewUnviewed" },
      { (s.status or "M") .. " ", s.status == "A" and "ReviewAdd" or s.status == "D" and "ReviewDel" or "ReviewDim" },
      { icon, icon_hl },
      { vim.fs.basename(path), path == cur and "ReviewCurrent" or nil },
      { s.add and (" +" .. s.add) or "", "ReviewAdd" },
      { s.del and (" -" .. s.del) or "", "ReviewDel" },
      { nf > 0 and ("  ⚑" .. nf) or "", "ReviewBug" },
      { nt > 0 and ("  ✎" .. nt) or "", "ReviewRisk" },
      { "  " .. vim.fs.dirname(path), "ReviewDim" },
    }, { kind = "file", path = path, detail = path })
  end
  add({})

  local agent_status = st.agent_job and "reviewing in the background…"
    or st.findings and (#st.findings == 0 and "no findings" or (#st.findings .. (#st.findings == 1 and " finding" or " findings")))
    or "not run"
  add({ { "Agent ", "ReviewSection" }, { agent_status, "ReviewDim" } }, {
    kind = "agent",
    run = function()
      if st.agent_job then
        return util.notify("Agent is still reviewing…")
      end
      util.run(function()
        if st.findings and util.select({ "Re-run", "Cancel" }, { prompt = "Re-run the agent review?" }) ~= "Re-run" then
          return
        end
        require("review.agent").start(st, { force = true })
        M.render()
      end)
    end,
  })
  for _, f in ipairs(st.findings or {}) do
    add({
      { ("  %-8s "):format(f.kind), KIND_HL[f.kind] },
      { ("%s:%d "):format(vim.fs.basename(f.path), f.lnum), "ReviewDim" },
      { oneline(f.message, 200) },
    }, {
      kind = "finding",
      path = f.path,
      lnum = f.lnum,
      detail = ("**%s** `%s:%d`\n\n%s"):format(f.kind, f.path, f.lnum, f.message),
    })
  end
  add({})

  local open = vim.tbl_filter(function(t)
    return not t.isResolved
  end, st.threads or {})
  local p = pending(st)
  add({
    { "Threads ", "ReviewSection" },
    { ("%d unresolved%s"):format(#open, p > 0 and (" · %d pending (yours)"):format(p) or ""), "ReviewDim" },
  }, { kind = "threads", run = review().refresh_threads })
  for _, t in ipairs(open) do
    local nodes = t.comments and t.comments.nodes or {}
    local c = nodes[1]
    if c then
      local l1 = review().thread_lines(t)
      local detail = {}
      for _, n in ipairs(nodes) do
        detail[#detail + 1] = ("**@%s**%s\n%s\n"):format(
          n.author and n.author.login or "ghost",
          n.state == "PENDING" and " _(pending)_" or "",
          vim.trim(n.body)
        )
      end
      add({
        { c.state == "PENDING" and "  ✎ " or "  ", "ReviewRisk" },
        { "@" .. (c.author and c.author.login or "ghost") .. " ", "ReviewSection" },
        { ("%s:%s "):format(vim.fs.basename(t.path), l1 or "file"), "ReviewDim" },
        { #nodes > 1 and ("(%d) "):format(#nodes) or "", "ReviewDim" },
        { oneline(c.body, 200) },
        { t.isOutdated and "  outdated" or "", "ReviewDim" },
      }, { kind = "thread", path = t.path, lnum = l1, detail = table.concat(detail, "\n") })
    end
  end
  add({})

  -- stylua: ignore
  for _, row in ipairs({
    { "<CR>", "open diff", "v", "viewed" },
    { "n", "next unviewed", "]r [r", "next/prev file" },
    { "K", "details/description", "h", "hunks" },
    { "a", "ask agent", "i", "impact", "s", "submit" },
    { "r", "refresh", "gx", "browser", "q", "hide", "Q", "end" },
    { "<leader>r", "+ key: same, from the diff" },
  }) do
    local chunks = {}
    for i = 1, #row, 2 do
      chunks[#chunks + 1] = { row[i], "ReviewKey" }
      chunks[#chunks + 1] = { " " .. row[i + 1] .. "  ", "ReviewDim" }
    end
    add(chunks)
  end

  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(b, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

--- Item under the panel cursor.
---@return review.Item?
local function item()
  return items[vim.api.nvim_win_get_cursor(0)[1]]
end

local function cursor_to(path)
  local st = review().active()
  local w = st and win(st)
  for lnum, it in pairs(w and items or {}) do
    if it.kind == "file" and it.path == path then
      return vim.api.nvim_win_set_cursor(w, { lnum, 0 })
    end
  end
end

local function act()
  local it = item()
  if not it then
    return
  end
  if it.run then
    it.run()
  elseif it.path then
    M.open(it.path, it.lnum)
  elseif it.kind == "header" then
    review().show_description()
  end
end

local function hover()
  local it = item()
  if it and it.detail and it.kind ~= "file" then
    vim.lsp.util.open_floating_preview(vim.split(it.detail, "\n"), "markdown", { border = "rounded", max_width = 90 })
  else
    review().show_description()
  end
end

local function create_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, NAME)
  vim.bo[b].filetype = "review"
  vim.bo[b].modifiable = false
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = b, nowait = true, desc = desc })
  end
  local function path()
    local it = item()
    return it and it.path
  end
  map("<CR>", act, "Open")
  map("o", act, "Open")
  map("<2-LeftMouse>", act, "Open")
  map("K", hover, "Details")
  map("v", function()
    local p = path()
    M.toggle_viewed(p)
    local st = review().active()
    local nxt = st and p and st.viewed[p] and M.next_file(st, p, 1, true)
    if nxt then
      cursor_to(nxt)
    end
  end, "Toggle viewed")
  map("n", function()
    local st = review().active()
    local f = st and M.next_file(st, current_path(st), 1, true)
    if f then
      M.open(f)
    else
      util.notify("Every file is viewed — s to submit")
    end
  end, "Next unviewed file")
  map("]r", function()
    M.jump(1)
  end, "Next changed file")
  map("[r", function()
    M.jump(-1)
  end, "Prev changed file")
  map("h", function()
    local st = review().active()
    Snacks.picker.git_diff({ base = st.merge_base, cwd = st.root })
  end, "Changed hunks")
  map("i", function()
    vim.api.nvim_set_current_win(main_win(review().active()) or 0)
    require("review.impact").open()
  end, "Impact (callers)")
  map("a", function()
    vim.api.nvim_set_current_win(main_win(review().active()) or 0)
    require("sidekick.cli").prompt()
  end, "Ask agent")
  map("s", M.submit, "Submit review")
  map("r", function()
    util.run(review().refresh_threads)
  end, "Refresh")
  map("gx", function()
    vim.ui.open(review().active().url)
  end, "Open in browser")
  map("q", M.hide, "Hide panel")
  map("Q", M.confirm_close, "End review")
  return b
end

function M.confirm_close()
  util.run(function()
    if util.select({ "End review", "Cancel" }, { prompt = "Close the review tab?" }) == "End review" then
      review().close()
    end
  end)
end

function M.hide()
  local st = review().active()
  local w = st and win(st)
  if w and #vim.api.nvim_tabpage_list_wins(st.tab) > 1 then
    vim.api.nvim_win_close(w, true)
  end
end

--- Show the panel (creating it on first use) and focus it.
function M.show()
  local st = review().active()
  if not st then
    return
  end
  local w = win(st)
  if not w then
    local b = buf() or create_buf()
    vim.api.nvim_set_current_tabpage(st.tab)
    vim.cmd(("topleft vertical %dsplit"):format(WIDTH))
    w = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w, b)
    for opt, val in pairs({
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      wrap = false,
      cursorline = true,
      winfixwidth = true,
      winfixbuf = true,
      list = false,
      spell = false,
    }) do
      vim.wo[w][opt] = val
    end
    vim.cmd("wincmd =") -- the panel keeps its width; the two sides split the rest evenly
  end
  M.render()
  vim.api.nvim_set_current_win(w)
  local cur = current_path(st)
  if cur then
    cursor_to(cur)
  end
end

--- `<leader>gR` inside a review: jump between the panel and the file window.
function M.toggle_focus()
  local st = review().active()
  local w = st and win(st)
  if w and vim.api.nvim_get_current_win() == w then
    vim.api.nvim_set_current_win(main_win(st) or w)
  else
    M.show()
  end
end

--- Called on BufEnter in the review tab: follow the diffed file in the panel.
--- The panel's actions inside the diff: <leader>r + the panel key (which-key lists them).
local function diff_keys(b)
  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = b, desc = desc })
  end
  map("n", "]r", function()
    M.jump(1)
  end, "Next changed file (review)")
  map("n", "[r", function()
    M.jump(-1)
  end, "Prev changed file (review)")
  local function cur()
    local st = review().active()
    return st, st and current_path(st)
  end
  -- stylua: ignore
  for _, k in ipairs({
    { "n", function()
      local st, p = cur()
      local f = st and M.next_file(st, p, 1, true)
      if f then M.open(f) else util.notify("Every file is viewed — <leader>rs to submit") end
    end, "Next unviewed file" },
    { "v", function()
      local st, p = cur()
      if not p then return end
      M.toggle_viewed(p)
      local f = st.viewed[p] and M.next_file(st, p, 1, true)
      if f then M.open(f) end
    end, "Toggle viewed (+ next unviewed)" },
    { "c", function() review().comment() end, "Comment on line" },
    { "K", function() review().show_description() end, "PR description" },
    { "h", function() local st = review().active() Snacks.picker.git_diff({ base = st.merge_base, cwd = st.root }) end, "Changed hunks" },
    { "i", function() require("review.impact").open() end, "Impact (callers)" },
    { "a", function() require("sidekick.cli").prompt() end, "Ask agent" },
    { "s", M.submit, "Submit review" },
    { "r", function() util.run(review().refresh_threads) end, "Refresh threads" },
    { "p", M.toggle_focus, "Panel (show / focus)" },
    { "x", function() vim.ui.open(review().active().url) end, "Open in browser" },
    { "q", M.confirm_close, "End review" },
  }) do
    map("n", "<leader>r" .. k[1], k[2], k[3])
  end
  map("x", "<leader>rc", function()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd.normal({ "\27", bang = true })
    review().comment({ math.min(l1, l2), math.max(l1, l2) })
  end, "Comment on lines")
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { "<leader>r", group = "review", buffer = b } })
  end
end

function M.on_enter(b)
  local st = review().active()
  if not st or vim.api.nvim_get_current_tabpage() ~= st.tab or b == buf() then
    return
  end
  local w = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(w).relative ~= "" then
    return
  end
  local rel = current_path(st)
  if not vim.b[b].review_keys then
    vim.b[b].review_keys = true
    diff_keys(b)
  end
  if win(st) then
    M.render()
    if rel then
      cursor_to(rel)
    end
  end
end

return M

-- PR review in a dedicated tab + reusable git worktree, so LSP, search, gitsigns and the agent all
-- see the PR head as real files. One worktree per repo is reused across reviews to keep Metals and
-- Bloop warm. See lua/plugins/review.lua for keys.
local gh = require("review.gh")
local util = require("review.util")
local notify, run, sh = util.notify, util.run, util.sh

local M = {}

---@class review.State
---@field number integer
---@field title string
---@field url string
---@field id string PR node id
---@field owner string
---@field name string
---@field author string
---@field body string
---@field base_ref string
---@field head string
---@field merge_base string
---@field root string worktree
---@field tab integer the PR's diffview tab
---@field files string[] changed paths (repo-relative)
---@field stats table<string, {status: string, add?: string, del?: string}>
---@field hunks table<string, integer[]> first new-side line of each hunk
---@field viewed table<string, boolean> GitHub's per-file "Viewed" state
---@field ci? string status check rollup of the head commit
---@field decision? string
---@field threads table[]
---@field pending_review? string
---@field findings? review.Finding[]
---@field agent_job? vim.SystemObj
M.state = nil ---@type review.State?

M.ns = {
  threads = vim.api.nvim_create_namespace("review.threads"),
  agent = vim.api.nvim_create_namespace("review.agent"),
}
-- their text is drawn as wrapped blocks under the line by review.notes
for _, ns in pairs(M.ns) do
  vim.diagnostic.config({ virtual_text = false, virtual_lines = false }, ns)
end

local group = vim.api.nvim_create_augroup("review", { clear = true })

function M.active()
  local st = M.state
  return st and vim.api.nvim_tabpage_is_valid(st.tab) and st or nil
end

--- Repo-relative path of `buf` if it lives in the review worktree.
function M.relpath(buf)
  local st = M.active()
  local file = vim.api.nvim_buf_get_name(buf or 0)
  return st and file ~= "" and vim.fs.relpath(st.root, file) or nil
end

--- Main checkout for `dir` (worktrees resolve to the repo they belong to).
local function main_checkout(dir)
  local common = sh({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, { cwd = dir })
  return vim.fs.dirname(common)
end

local function origin_is(dir, nwo)
  local r = vim.system({ "git", "-C", dir, "remote", "get-url", "origin" }, { text = true }):wait()
  local url = r.code == 0 and vim.trim(r.stdout):lower():gsub("%.git$", "") or ""
  return url:sub(-#nwo - 1) == "/" .. nwo:lower() or url:sub(-#nwo - 1) == ":" .. nwo:lower()
end

--- Local checkout of GitHub repo `nwo` ("owner/name"); without it, the current directory's repo.
--- Looks in the current repo, `vim.g.review_checkouts[nwo]`, then ~/<name>.
local function source_repo(nwo)
  if not nwo then
    return main_checkout(vim.fn.getcwd())
  end
  local cwd_ok, cwd = pcall(main_checkout, vim.fn.getcwd())
  local candidates = {
    cwd_ok and cwd or nil,
    (vim.g.review_checkouts or {})[nwo],
    vim.fs.joinpath(vim.env.HOME, nwo:match("/(.+)$")),
  }
  for _, dir in pairs(candidates) do
    dir = vim.fs.normalize(dir)
    if vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) and origin_is(dir, nwo) then
      return dir
    end
  end
  error(
    ("No local checkout of %s (clone it to ~/%s or set vim.g.review_checkouts)"):format(nwo, nwo:match("/(.+)$")),
    0
  )
end

local function worktree(src)
  local root = vim.fs.joinpath(vim.fn.stdpath("cache"), "review", vim.fs.basename(src))
  if not vim.uv.fs_stat(vim.fs.joinpath(root, ".git")) then
    sh({ "git", "-C", src, "worktree", "prune" })
    vim.fn.mkdir(vim.fs.dirname(root), "p")
    sh({ "git", "-C", src, "worktree", "add", "--detach", "--quiet", root })
  end
  return vim.uv.fs_realpath(root) or root -- buffer names are resolved paths
end

--- Buffers loaded from the worktree.
local function review_bufs()
  local st, ret = M.active(), {}
  for _, buf in ipairs(st and vim.api.nvim_list_bufs() or {}) do
    if vim.api.nvim_buf_is_loaded(buf) and M.relpath(buf) then
      ret[#ret + 1] = buf
    end
  end
  return ret
end

--- Diff worktree buffers against the merge-base so signs, ]h/[h and hunk previews show the PR.
--- Runs on GitSignsUpdate once gitsigns has a cache for the buffer, i.e. after its initial diff:
--- earlier (on_attach, or the attach-time update event) the base change is lost or races.
local function gitsigns_base(buf)
  local st, gs = M.active(), package.loaded.gitsigns
  local ok, cache = pcall(require, "gitsigns.cache")
  if st and gs and ok and cache.cache[buf] and vim.b[buf].review_base ~= st.merge_base and M.relpath(buf) then
    vim.b[buf].review_base = st.merge_base
    vim.api.nvim_buf_call(buf, function()
      gs.change_base(st.merge_base)
    end)
  end
end

--- Start and end line of a thread. File-level comments posted from here carry their lines as a
--- `L12` / `L12-L14` body prefix.
function M.thread_lines(t)
  local first = t.comments and t.comments.nodes and t.comments.nodes[1]
  local l1, l2 = (first and first.body or ""):match("^`L(%d+)%-?L?(%d*)`:")
  if l1 then
    return tonumber(l1), tonumber(l2) or tonumber(l1)
  end
  if t.line then
    return t.startLine or t.line, t.line
  end
end

local function thread_diagnostics(st, rel)
  local ret = {}
  for _, t in ipairs(st.threads or {}) do
    local l1, l2 = M.thread_lines(t)
    if t.path == rel and l1 and not t.isResolved then
      local msgs, parts = {}, {}
      for i, c in ipairs(t.comments and t.comments.nodes or {}) do
        local who = ("@%s%s"):format(
          c.author and c.author.login or "ghost",
          c.state == "PENDING" and " (pending)" or ""
        )
        local body = vim.trim((c.body:gsub("^`L%d+%-?L?%d*`:%s*", "")))
        msgs[#msgs + 1] = ("%s%s: %s"):format(i > 1 and "  ↳ " or "", who, body)
        parts[#parts + 1] = { head = (i > 1 and "↳ " or "✎ ") .. who, text = body }
      end
      ret[#ret + 1] = {
        lnum = l1 - 1,
        end_lnum = l2 - 1,
        col = 0,
        severity = vim.diagnostic.severity.INFO,
        source = "github",
        message = table.concat(msgs, "\n"),
        user_data = { parts = parts },
      }
    end
  end
  return ret
end

--- Apply GitHub threads and agent findings to `buf` as diagnostics.
function M.decorate(buf)
  local st, rel = M.active(), M.relpath(buf)
  if not (st and rel) then
    return
  end
  local threads, findings = thread_diagnostics(st, rel), require("review.agent").diagnostics(st, rel)
  vim.diagnostic.set(M.ns.threads, buf, threads)
  vim.diagnostic.set(M.ns.agent, buf, findings)
  local notes = {}
  for _, d in ipairs(vim.list_extend(vim.deepcopy(threads), findings)) do
    notes[#notes + 1] = { lnum = d.end_lnum or d.lnum, severity = d.severity, parts = d.user_data.parts }
  end
  require("review.notes").render(buf, notes)
end

local function decorate_all()
  for _, buf in ipairs(review_bufs()) do
    M.decorate(buf)
  end
end

function M.refresh_threads()
  local st = M.active()
  if not st then
    return
  end
  local data = gh.graphql(gh.THREADS, { owner = st.owner, name = st.name, number = st.number })
  local pr = data.repository.pullRequest
  st.threads = pr.reviewThreads.nodes or {}
  st.pending_review = pr.reviews.nodes and pr.reviews.nodes[1] and pr.reviews.nodes[1].id or nil
  st.decision = pr.reviewDecision
  local commit = pr.commits.nodes and pr.commits.nodes[1] and pr.commits.nodes[1].commit
  st.ci = commit and commit.statusCheckRollup and commit.statusCheckRollup.state or nil
  for _, f in ipairs(pr.files and pr.files.nodes or {}) do
    st.viewed[f.path] = f.viewerViewedState == "VIEWED"
  end
  decorate_all()
  require("review.panel").render()
end

--- PR title and description in a float (again to focus it and scroll).
function M.show_description()
  local st = M.active()
  if not st then
    return
  end
  local lines = {
    ("# #%d %s"):format(st.number, st.title),
    "",
    ("@%s · %s → %s · %s"):format(st.author, st.head:sub(1, 10), st.base_ref, st.url),
    "",
  }
  vim.list_extend(lines, vim.split(vim.trim(st.body ~= "" and st.body or "_No description._"), "\r?\n"))
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focus_id = "review_description",
    max_width = math.min(100, vim.o.columns - 10),
    max_height = math.floor(vim.o.lines * 0.7),
  })
end

--- Per-file change status and line counts, and the first line of each hunk, ignoring whitespace
--- (like GitHub's "Hide whitespace"): files whose only edits are whitespace get no entry.
local function diff_info(root, base, head)
  local stats, hunks, counted = {}, {}, {}
  for _, l in
    ipairs(vim.split(sh({ "git", "diff", "--name-status", base, head }, { cwd = root }), "\n", { trimempty = true }))
  do
    local parts = vim.split(l, "\t")
    stats[parts[#parts]] = { status = parts[1]:sub(1, 1) }
  end
  for _, l in
    ipairs(vim.split(sh({ "git", "diff", "-w", "--numstat", base, head }, { cwd = root }), "\n", { trimempty = true }))
  do
    local add, del, path = l:match("^(%S+)%s+(%S+)%s+(.+)$")
    path = path and path:gsub("^(.-){(.-) => (.-)}(.*)$", "%1%3%4"):gsub("^.* => ", "")
    if path and stats[path] then
      counted[path] = true
      if add ~= "-" then
        stats[path].add, stats[path].del = add, del
      end
    end
  end
  -- --name-status ignores -w; a modified file -w drops from --numstat changed only whitespace
  for path, s in pairs(stats) do
    if s.status == "M" and not counted[path] then
      stats[path] = nil
    end
  end
  local file
  for l in vim.gsplit(sh({ "git", "diff", "-w", "-U0", "--no-color", base, head }, { cwd = root }), "\n") do
    if l:match("^%+%+%+ ") then
      file = l:match("^%+%+%+ b/(.+)$") -- nil for deletions
    end
    local start = l:match("^@@ %-%S+ %+(%d+)")
    if file and start then
      hunks[file] = hunks[file] or {}
      table.insert(hunks[file], math.max(tonumber(start), 1))
    end
  end
  return stats, hunks
end

--- Open PR `ref` (number or URL) for review. Without `ref`, pick from PRs waiting on you.
function M.start(ref)
  if not ref then
    return require("review.inbox").open()
  end
  run(function()
    ref = vim.trim(tostring(ref))
    local number = tonumber(ref:match("/pull/(%d+)") or ref:match("^#?(%d+)$"))
    assert(number, "Not a PR number or URL: " .. tostring(ref))
    local src = source_repo(ref:match("github%.com/([^/]+/[^/]+)/pull/"))
    notify(("Fetching PR #%d…"):format(number))
    local pr = gh.json({
      "pr",
      "view",
      tostring(number),
      "--json",
      "number,title,url,baseRefName,headRefOid,id,author,body",
    }, { cwd = src })
    sh({
      "git",
      "-C",
      src,
      "fetch",
      "--quiet",
      "--no-tags",
      "origin",
      ("+refs/pull/%d/head:refs/review/pr-%d"):format(number, number),
      ("+refs/heads/%s:refs/remotes/origin/%s"):format(pr.baseRefName, pr.baseRefName),
    })
    local root = worktree(src)
    if sh({ "git", "status", "--porcelain", "--untracked-files=no" }, { cwd = root }) ~= "" then
      local choice = util.select({ "Discard and continue", "Cancel" }, {
        prompt = "Review worktree has local edits (" .. root .. ")",
      })
      assert(choice == "Discard and continue", "Cancelled")
    end
    M.close()
    sh({ "git", "checkout", "--quiet", "--detach", "--force", pr.headRefOid }, { cwd = root })
    local merge_base = sh({ "git", "merge-base", pr.headRefOid, "origin/" .. pr.baseRefName }, { cwd = root })
    local files = sh({ "git", "diff", "--name-only", merge_base, pr.headRefOid }, { cwd = root })
    local owner, name = pr.url:match("github%.com/([^/]+)/([^/]+)/pull")
    local stats, hunks = diff_info(root, merge_base, pr.headRefOid)

    M.state = {
      number = pr.number,
      title = pr.title,
      url = pr.url,
      id = pr.id,
      owner = owner,
      name = name,
      author = pr.author and pr.author.login or "?",
      body = pr.body or "",
      base_ref = pr.baseRefName,
      head = pr.headRefOid,
      merge_base = merge_base,
      root = root,
      tab = -1, -- set by panel.open_view
      files = require("review.rank").sort(vim.tbl_filter(function(p)
        return stats[p] ~= nil
      end, vim.split(files, "\n", { trimempty = true }))),
      whitespace_only = #vim.tbl_filter(function(p)
        return stats[p] == nil
      end, vim.split(files, "\n", { trimempty = true })),
      stats = stats,
      hunks = hunks,
      viewed = {},
      threads = {},
    }
    local panel = require("review.panel")
    panel.open_view(M.state)
    M.sync_diffopt()
    panel.show()
    M.show_description()
    require("review.agent").start(M.state)
    M.refresh_threads()
    panel.render()
  end)
end

function M.comment(range)
  local st = M.active()
  local rel = M.relpath(0)
  if not (st and rel) then
    return notify("Not a file in the active review", vim.log.levels.WARN)
  end
  local l1, l2 = range and range[1] or vim.fn.line("."), range and range[2] or vim.fn.line(".")
  local finding = require("review.agent").at(st, rel, l1, l2)
  local loc = l1 == l2 and ("L" .. l2) or ("L%d-L%d"):format(l1, l2)
  Snacks.win({
    title = (" Comment %s:%s "):format(vim.fs.basename(rel), loc),
    footer = " <c-s> post · q cancel ",
    footer_pos = "center",
    text = finding and finding.message or "",

    width = 0.6,
    height = 0.3,
    border = "rounded",
    bo = { buftype = "nofile", modifiable = true, filetype = "markdown" },
    wo = { wrap = true, linebreak = true },
    fixbuf = true,
    on_win = function()
      vim.cmd.startinsert({ bang = finding ~= nil })
    end,
    keys = {
      q = "close",
      post = {
        "<c-s>",
        function(win)
          local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), "\n"))
          win:close()
          vim.cmd.stopinsert()
          if body ~= "" then
            M.post_comment(rel, l1, l2, body)
          end
        end,
        mode = { "n", "i" },
      },
    },
  })
end

--- Adds a thread to your pending review (created on demand); nothing is public until you submit.
function M.post_comment(rel, l1, l2, body)
  run(function()
    local st = assert(M.active(), "No active review")
    local input = {
      pullRequestId = st.id,
      path = rel,
      line = l2,
      side = "RIGHT",
      startLine = l1 < l2 and l1 or nil,
      startSide = l1 < l2 and "RIGHT" or nil,
      body = body,
    }
    -- GitHub returns a null thread (no error) for lines outside the diff; fall back to a file-level
    -- comment that names the lines.
    local res = gh.graphql(gh.ADD_THREAD, { input = input }).addPullRequestReviewThread
    if not res.thread then
      input = {
        pullRequestId = st.id,
        path = rel,
        subjectType = "FILE",
        body = ("`%s`: %s"):format(l1 == l2 and ("L" .. l2) or ("L%d-L%d"):format(l1, l2), body),
      }
      res = gh.graphql(gh.ADD_THREAD, { input = input }).addPullRequestReviewThread
      assert(res.thread, "GitHub rejected the comment on " .. rel)
    end
    notify("Comment added to your pending review")
    M.refresh_threads()
  end)
end

function M.submit(event)
  run(function()
    local st = assert(M.active(), "No active review")
    local labels = { APPROVE = "Approve", REQUEST_CHANGES = "Request changes", COMMENT = "Comment" }
    local body = util.input({ prompt = labels[event] .. " — summary (optional): " })
    if body == nil then
      return
    end
    assert(event ~= "REQUEST_CHANGES" or body ~= "" or st.pending_review, "Request changes needs a summary or comments")
    M.refresh_threads()
    local res
    if st.pending_review then
      res = gh.graphql(gh.SUBMIT, {
        input = { pullRequestReviewId = st.pending_review, event = event, body = body ~= "" and body or nil },
      }).submitPullRequestReview
    else
      res = gh.graphql(gh.ADD_REVIEW, {
        input = { pullRequestId = st.id, event = event, body = body ~= "" and body or nil },
      }).addPullRequestReview
    end
    notify(("%s: %s"):format(labels[event], res.pullRequestReview.url))
    M.refresh_threads()
  end)
end

function M.close()
  local st = M.state
  if not st then
    return
  end
  if st.agent_job then
    local job = st.agent_job
    st.agent_job = nil
    pcall(job.kill, job, 15)
  end
  M.state = nil
  M.sync_diffopt()
  for _, v in ipairs(package.loaded["diffview.lib"] and require("diffview.lib").views or {}) do
    if v.tabpage == st.tab then
      v:close()
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if (vim.fs.relpath(st.root, name) or name:match("^review://")) and not vim.bo[buf].modified then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local added_iwhite = false

--- Diffs in the review tab ignore whitespace; elsewhere 'diffopt' (global) is left as the user had it.
function M.sync_diffopt()
  local st = M.active()
  local in_review = st and vim.api.nvim_get_current_tabpage() == st.tab
  local has = vim.tbl_contains(vim.opt.diffopt:get(), "iwhiteall")
  if in_review and not has then
    vim.opt.diffopt:append("iwhiteall")
    added_iwhite = true
  elseif not in_review and added_iwhite then
    vim.opt.diffopt:remove("iwhiteall")
    added_iwhite = false
  end
end

--- `<leader>gR`: start a review, or jump between the review panel and the file.
function M.menu()
  local st = M.active()
  if not st or vim.api.nvim_get_current_tabpage() ~= st.tab then
    return M.start()
  end
  require("review.panel").toggle_focus()
end

--- Sidekick `{pr}` context: tells the agent what "the change" is.
function M.context()
  local st = M.active()
  if st then
    return ("Reviewing PR #%d %q by @%s (%s). The PR's change is `git diff -w %s HEAD` (whitespace ignored)."):format(
      st.number,
      st.title,
      st.author,
      st.url,
      st.merge_base:sub(1, 12)
    )
  end
  return "The change under discussion is this branch: `git diff --merge-base origin/development`."
end

function M.setup()
  vim.api.nvim_create_user_command("Review", function(a)
    M.start(a.args ~= "" and a.args or nil)
  end, { nargs = "?", desc = "Review a GitHub PR (number or URL)" })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      M.sync_diffopt()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    callback = function(ev)
      if ev.data and ev.data.buffer then
        gitsigns_base(ev.data.buffer)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if M.state then
        require("review.panel").on_enter(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      if M.state and not vim.api.nvim_tabpage_is_valid(M.state.tab) then
        M.close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      if M.relpath(ev.buf) then
        M.decorate(ev.buf)
      end
    end,
  })
  -- diffview fills its windows asynchronously; redraw once both sides are in place
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = vim.schedule_wrap(function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if M.relpath(b) then
          M.decorate(b)
        end
      end
    end),
  })
  -- comment blocks wrap to the window width
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, w in ipairs(vim.v.event.windows or {}) do
        local b = vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w)
        if b and M.relpath(b) then
          M.decorate(b)
        end
      end
    end,
  })
end

return M

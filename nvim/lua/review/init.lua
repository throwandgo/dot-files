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
---@field tab integer
---@field files string[] changed paths (repo-relative)
---@field threads table[]
---@field pending_review? string
---@field findings? review.Finding[]
---@field agent_job? vim.SystemObj
M.state = nil ---@type review.State?

M.ns = {
  threads = vim.api.nvim_create_namespace("review.threads"),
  agent = vim.api.nvim_create_namespace("review.agent"),
}

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

--- Main checkout for the current directory (worktrees resolve to the repo they belong to).
local function source_repo()
  local common = sh({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, { cwd = vim.fn.getcwd() })
  return vim.fs.dirname(common)
end

local function worktree(src)
  local root = vim.fs.joinpath(vim.fn.stdpath("cache"), "review", vim.fs.basename(src))
  if not vim.uv.fs_stat(vim.fs.joinpath(root, ".git")) then
    sh({ "git", "-C", src, "worktree", "prune" })
    vim.fn.mkdir(vim.fs.dirname(root), "p")
    sh({ "git", "-C", src, "worktree", "add", "--detach", "--quiet", root })
  end
  return root
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
local function thread_lines(t)
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
    local l1, l2 = thread_lines(t)
    if t.path == rel and l1 and not t.isResolved then
      local msgs = {}
      for i, c in ipairs(t.comments and t.comments.nodes or {}) do
        msgs[#msgs + 1] = ("%s@%s%s: %s"):format(
          i > 1 and "  ↳ " or "",
          c.author and c.author.login or "ghost",
          c.state == "PENDING" and " (pending)" or "",
          vim.trim(c.body)
        )
      end
      ret[#ret + 1] = {
        lnum = l1 - 1,
        end_lnum = l2 - 1,
        col = 0,
        severity = vim.diagnostic.severity.INFO,
        source = "github",
        message = table.concat(msgs, "\n"),
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
  vim.diagnostic.set(M.ns.threads, buf, thread_diagnostics(st, rel))
  vim.diagnostic.set(M.ns.agent, buf, require("review.agent").diagnostics(st, rel))
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
  decorate_all()
end

local function overview(st)
  local numstat = sh({ "git", "diff", "--numstat", st.merge_base, st.head }, { cwd = st.root })
  local lines = {
    ("# #%d %s"):format(st.number, st.title),
    "",
    ("@%s · %s → %s · %s"):format(st.author, st.head:sub(1, 10), st.base_ref, st.url),
    "",
  }
  vim.list_extend(lines, vim.split(vim.trim(st.body ~= "" and st.body or "_No description._"), "\r?\n"))
  vim.list_extend(lines, { "", ("## Files (%d) — gf to open"):format(#st.files), "" })
  for _, l in ipairs(vim.split(numstat, "\n", { trimempty = true })) do
    local add, del, path = l:match("^(%S+)%s+(%S+)%s+(.+)$")
    if path then
      lines[#lines + 1] = ("%s  +%s -%s"):format(path, add, del)
    end
  end
  local name = ("review://pr-%d"):format(st.number)
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].filetype = false, "markdown"
  vim.api.nvim_set_current_buf(buf)
end

--- Open PR `ref` (number or URL) for review. Without `ref`, pick from PRs awaiting your review.
function M.start(ref)
  if not ref then
    return Snacks.picker.gh_pr({
      title = "  Review requested",
      search = "review-requested:@me",
      confirm = function(picker, item)
        picker:close()
        if item then
          M.start(item.number)
        end
      end,
    })
  end
  run(function()
    ref = vim.trim(tostring(ref))
    local number = tonumber(ref:match("/pull/(%d+)") or ref:match("^#?(%d+)$"))
    assert(number, "Not a PR number or URL: " .. tostring(ref))
    local src = source_repo()
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
    M.close({ keep_tab = true })
    sh({ "git", "checkout", "--quiet", "--detach", "--force", pr.headRefOid }, { cwd = root })
    local merge_base = sh({ "git", "merge-base", pr.headRefOid, "origin/" .. pr.baseRefName }, { cwd = root })
    local files = sh({ "git", "diff", "--name-only", merge_base, pr.headRefOid }, { cwd = root })
    local owner, name = pr.url:match("github%.com/([^/]+)/([^/]+)/pull")

    local tab = M.state and vim.api.nvim_tabpage_is_valid(M.state.tab) and M.state.tab
    if tab then
      vim.api.nvim_set_current_tabpage(tab)
    else
      vim.cmd.tabnew()
      tab = vim.api.nvim_get_current_tabpage()
    end
    vim.cmd.tcd(vim.fn.fnameescape(root))
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
      tab = tab,
      files = vim.split(files, "\n", { trimempty = true }),
      threads = {},
    }
    vim.t[tab].review = pr.number
    overview(M.state)
    require("review.agent").start(M.state)
    M.refresh_threads()
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

local function pick_threads(st)
  local items = {}
  for _, t in ipairs(st.threads or {}) do
    local c = t.comments and t.comments.nodes and t.comments.nodes[1]
    if c and not t.isResolved then
      items[#items + 1] = {
        file = t.path,
        cwd = st.root,
        pos = { thread_lines(t) or 1, 0 },
        text = ("@%s %s"):format(c.author and c.author.login or "ghost", (c.body:gsub("%s+", " "))),
        label = t.isOutdated and "outdated" or nil,
      }
    end
  end
  Snacks.picker.pick({ title = "Unresolved threads", items = items, format = "file" })
end

function M.close(opts)
  local st = M.state
  if not st then
    return
  end
  if st.agent_job then
    local job = st.agent_job
    st.agent_job = nil
    pcall(job.kill, job, 15)
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if (vim.fs.relpath(st.root, name) or name:match("^review://")) and not vim.bo[buf].modified then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if not (opts and opts.keep_tab) then
    if vim.api.nvim_tabpage_is_valid(st.tab) and #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(st.tab))
    end
    M.state = nil
  end
end

--- `<leader>gR`: start a review, or the action menu when inside one.
function M.menu()
  local st = M.active()
  if not st or vim.api.nvim_get_current_tabpage() ~= st.tab then
    return M.start()
  end
  local agent = require("review.agent")
  local actions = {
    {
      "Overview",
      function()
        run(function()
          overview(st)
        end)
      end,
    },
    {
      "Changed hunks",
      function()
        Snacks.picker.git_diff({ base = st.merge_base, cwd = st.root })
      end,
    },
    {
      agent.label(st),
      function()
        agent.open(st)
      end,
    },
    {
      "Impact: callers of changed code",
      function()
        require("review.impact").open()
      end,
    },
    {
      ("Unresolved threads (%d)"):format(#vim.tbl_filter(function(t)
        return not t.isResolved
      end, st.threads or {})),
      function()
        pick_threads(st)
      end,
    },
    {
      "Refresh threads",
      function()
        run(M.refresh_threads)
      end,
    },
    {
      "Submit: Approve",
      function()
        M.submit("APPROVE")
      end,
    },
    {
      "Submit: Request changes",
      function()
        M.submit("REQUEST_CHANGES")
      end,
    },
    {
      "Submit: Comment",
      function()
        M.submit("COMMENT")
      end,
    },
    {
      "Re-run agent review",
      function()
        agent.start(st, { force = true })
      end,
    },
    {
      "Open in browser",
      function()
        vim.ui.open(st.url)
      end,
    },
    {
      "Close review",
      function()
        M.close()
      end,
    },
  }
  vim.ui.select(actions, {
    prompt = ("PR #%d %s"):format(st.number, st.title),
    format_item = function(a)
      return a[1]
    end,
  }, function(a)
    if a then
      a[2]()
    end
  end)
end

--- Sidekick `{pr}` context: tells the agent what "the change" is.
function M.context()
  local st = M.active()
  if st then
    return ("Reviewing PR #%d %q by @%s (%s). The PR's change is `git diff %s HEAD`."):format(
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
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    callback = function(ev)
      if ev.data and ev.data.buffer then
        gitsigns_base(ev.data.buffer)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if M.relpath(ev.buf) then
        M.decorate(ev.buf)
      end
    end,
  })
end

return M

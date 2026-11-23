-- PR lists from GitHub search: the review inbox (`<leader>gR`, every open PR waiting on you across
-- repos) and your own open PRs (the homepage). A PR matching several queries keeps the first
-- query's label (direct asks beat team asks). Only PRs active in the last `M.DAYS` days count:
-- anything quieter is parked, and skipping it keeps the lists short and the searches fast.
local gh = require("review.gh")
local util = require("review.util")

local M = {}

M.DAYS = 7
M.WINDOW = ("active in last %dd"):format(M.DAYS)

local OPEN = "is:pr is:open archived:false "
local WAITING = OPEN .. "draft:false -author:@me "

---@class review.inbox.Query
---@field label string
---@field hl? string
---@field q string full GitHub search query
---@field threads? boolean also count unresolved review threads (heavy: keep to short lists)
---@field first? integer rows to fetch (default 100; 0 = count only)

---@type review.inbox.Query[]
M.queries = {
  { label = "you", hl = "DiagnosticWarn", q = WAITING .. "repo:metropolis-io/web user-review-requested:@me" },
  { label = "you", hl = "DiagnosticWarn", q = WAITING .. "repo:metropolis-io/site user-review-requested:@me" },
  -- the team stays requested after round robin picks someone, so this is LNE's whole queue
  {
    label = "LNE",
    hl = "DiagnosticInfo",
    q = WAITING
      .. "repo:metropolis-io/site team-review-requested:metropolis-io/metropolis-lne -user-review-requested:@me",
  },
}

---@type review.inbox.Query
M.mine_query =
  { label = "mine", q = OPEN .. "author:@me org:metropolis-io sort:updated-desc", threads = true, first = 30 }

-- GitHub search costs ~3s per 100 rows whatever the fields, so lists that only need a few rows
-- (the homepage) ask for few, and the picker-only fields (body, other reviewers) are optional.
local FIELDS = [[
  issueCount
  nodes {
    ... on PullRequest {
      number title url updatedAt reviewDecision isDraft mergeable
      author { login }
      repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      %s
    }
  }
]]
local THREADS = "reviewThreads(first: 100) { nodes { isResolved } }"
local DETAILS = "body reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }"

local CI = {
  SUCCESS = { "✓", "DiagnosticOk" },
  FAILURE = { "✗", "DiagnosticError" },
  ERROR = { "✗", "DiagnosticError" },
  PENDING = { "●", "DiagnosticWarn" },
  EXPECTED = { "●", "DiagnosticWarn" },
}

local DECISION = {
  APPROVED = { "approved", "DiagnosticOk" },
  CHANGES_REQUESTED = { "changes requested", "DiagnosticError" },
  REVIEW_REQUIRED = { "awaiting review", "Comment" },
}

--- "5m", "3h", "2d" since an ISO-8601 UTC timestamp.
function M.ago(iso)
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  local utc_offset = os.time() - os.time(os.date("!*t") --[[@as osdate]])
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) + utc_offset
  local secs = math.max(os.time() - t, 0)
  for _, u in ipairs({ { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
    if secs >= u[1] then
      return math.floor(secs / u[1]) .. u[2]
    end
  end
  return "now"
end

local function to_item(pr, q, me)
  local others = {}
  for _, r in ipairs(pr.reviewRequests and pr.reviewRequests.nodes or {}) do
    local login = r.requestedReviewer and r.requestedReviewer.login
    if login and login ~= me then
      others[#others + 1] = "@" .. login
    end
  end
  local unresolved = #vim.tbl_filter(function(t)
    return not t.isResolved
  end, pr.reviewThreads and pr.reviewThreads.nodes or {})
  local c = pr.commits.nodes[1]
  local author = pr.author and pr.author.login or "ghost"
  return {
    label = q.label,
    label_hl = q.hl,
    repo = pr.repository.nameWithOwner,
    number = pr.number,
    title = pr.title,
    url = pr.url,
    author = author,
    updated = pr.updatedAt,
    ci = c and c.commit.statusCheckRollup and c.commit.statusCheckRollup.state,
    decision = pr.reviewDecision,
    draft = pr.isDraft,
    conflicts = pr.mergeable == "CONFLICTING",
    unresolved = unresolved,
    others = others,
    text = ("%s #%d %s %s %s"):format(pr.repository.nameWithOwner, pr.number, pr.title, author, q.label),
    preview = {
      ft = "markdown",
      text = ("# %s\n\n%s #%d by @%s · updated %s ago%s\n\n%s"):format(
        pr.title,
        pr.repository.nameWithOwner,
        pr.number,
        author,
        M.ago(pr.updatedAt),
        #others > 0 and ("\nAlso requested: " .. table.concat(others, ", ")) or "",
        (pr.body or ""):gsub("\r", "")
      ),
    },
  }
end

--- Items for `queries` in one request, deduped in query order, plus each query's total match count.
---@param queries review.inbox.Query[]
---@param opts? { details?: boolean } details: body and other reviewers (for the picker preview)
---@return table[] items, integer[] counts
function M.search(queries, opts)
  opts = opts or {}
  local parts = {}
  local since = " updated:>=" .. os.date("!%Y-%m-%d", os.time() - M.DAYS * 86400)
  for i, q in ipairs(queries) do
    local extra = (q.threads and THREADS or "") .. " " .. (opts.details and DETAILS or "")
    parts[#parts + 1] = ("q%d: search(query: %q, type: ISSUE, first: %d) { %s }"):format(
      i,
      q.q .. since,
      q.first or 100,
      FIELDS:format(extra)
    )
  end
  local data = gh.graphql("query {\n  viewer { login }\n" .. table.concat(parts, "\n") .. "\n}", vim.empty_dict())
  local seen, items, counts = {}, {}, {}
  for i, q in ipairs(queries) do
    local res = data["q" .. i]
    counts[i] = res.issueCount
    if not q.first and res.issueCount > #res.nodes then
      util.notify(("%s: showing %d of %d PRs"):format(q.q, #res.nodes, res.issueCount), vim.log.levels.WARN)
    end
    for _, pr in ipairs(res.nodes) do
      if pr.url and not seen[pr.url] then
        seen[pr.url] = true
        items[#items + 1] = to_item(pr, q, data.viewer.login)
      end
    end
  end
  return items, counts
end

--- PRs waiting on you: direct asks first, then most recently updated.
function M.fetch()
  local items = M.search(M.queries, { details = true })
  table.sort(items, function(a, b)
    if (a.label == "you") ~= (b.label == "you") then
      return a.label == "you"
    end
    return a.updated > b.updated
  end)
  return items
end

--- Your open PRs, most recently updated first.
---@param opts? { details?: boolean }
function M.mine(opts)
  return M.search({ M.mine_query }, opts)
end

--- Queue sizes for the homepage, in one count-only request.
---@return { mine: integer, you: integer, team: integer }
function M.counts()
  local queries = vim.list_extend({ M.mine_query }, M.queries)
  queries = vim.tbl_map(function(q)
    return vim.tbl_extend("force", q, { first = 0 })
  end, queries)
  local _, counts = M.search(queries)
  local r = { mine = counts[1], you = 0, team = 0 }
  for i, q in ipairs(M.queries) do
    local k = q.label == "you" and "you" or "team"
    r[k] = r[k] + counts[i + 1]
  end
  return r
end

--- CI, review state, unresolved threads and conflicts as highlighted chunks.
---@return {[1]:string, [2]:string?}[]
function M.status(item)
  local ci = CI[item.ci or ""] or { " ", nil }
  local ret = { { ci[1] .. " ", ci[2] } }
  if item.draft then
    ret[#ret + 1] = { "draft", "Comment" }
  elseif DECISION[item.decision or ""] then
    ret[#ret + 1] = DECISION[item.decision]
  end
  if item.unresolved and item.unresolved > 0 then
    ret[#ret + 1] = { " ✎" .. item.unresolved, "DiagnosticInfo" }
  end
  if item.conflicts then
    ret[#ret + 1] = { " conflicts", "DiagnosticError" }
  end
  return ret
end

local function format(item)
  local mine = item.label == "mine"
  local ret = {}
  if not mine then
    ret[#ret + 1] = { ("%-4s"):format(item.label), item.label_hl }
  end
  vim.list_extend(ret, {
    { ("%-5s"):format(item.repo:match("/(.+)$")), "Comment" },
    { ("#%-6d"):format(item.number), "SnacksPickerIdx" },
  })
  local status = M.status(item)
  if mine then
    vim.list_extend(ret, status)
    ret[#ret + 1] = { "  " }
  else
    ret[#ret + 1] = status[1]
  end
  ret[#ret + 1] = { item.title }
  if not mine then
    ret[#ret + 1] = { "  @" .. item.author, "Comment" }
  end
  ret[#ret + 1] = { " · " .. M.ago(item.updated), "Comment" }
  if not mine then
    for i = 2, #status do
      ret[#ret + 1] = { " ·" .. (status[i][1]:sub(1, 1) == " " and "" or " ") .. status[i][1], status[i][2] }
    end
    if item.label ~= "you" and #item.others > 0 then
      ret[#ret + 1] = { " → " .. table.concat(item.others, " "), "DiagnosticHint" }
    end
  end
  return ret
end

--- Picker over PR items; <CR> opens the review cockpit, <c-o> the browser.
function M.pick(title, items)
  Snacks.picker({
    title = ("%s (%d, %s)"):format(title, #items, M.WINDOW),
    items = items,
    format = format,
    preview = "preview",
    sort = { fields = { "score:desc", "idx" } },
    matcher = { sort_empty = false },
    confirm = function(picker, item)
      picker:close()
      if item then
        require("review").start(item.url)
      end
    end,
    actions = {
      browse = function(_, item)
        vim.ui.open(item.url)
      end,
    },
    win = { input = { keys = { ["<c-o>"] = { "browse", mode = { "n", "i" }, desc = "Open in browser" } } } },
  })
end

function M.open()
  util.run(function()
    util.notify("Loading PRs waiting on you…")
    M.pick("  PRs waiting on you", M.fetch())
  end)
end

function M.open_mine()
  util.run(function()
    util.notify("Loading your PRs…")
    M.pick("  My PRs", M.mine({ details = true }))
  end)
end

return M

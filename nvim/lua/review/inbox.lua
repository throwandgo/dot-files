-- `<leader>gR` inbox: every open PR waiting on you, across repos, in one picker. Each query is a
-- GitHub search; a PR matching several keeps the first query's label (direct asks beat team asks).
local gh = require("review.gh")
local util = require("review.util")

local M = {}

local BASE = "is:pr is:open draft:false -author:@me archived:false "

---@type { label: string, hl: string, q: string }[]
M.queries = {
  { label = "you", hl = "DiagnosticWarn", q = "repo:metropolis-io/web user-review-requested:@me" },
  { label = "you", hl = "DiagnosticWarn", q = "repo:metropolis-io/site user-review-requested:@me" },
  -- the team stays requested after round robin picks someone, so this is LNE's whole queue
  {
    label = "LNE",
    hl = "DiagnosticInfo",
    q = "repo:metropolis-io/site team-review-requested:metropolis-io/metropolis-lne",
  },
}

local FIELDS = [[
  issueCount
  nodes {
    ... on PullRequest {
      number title url body updatedAt reviewDecision
      author { login }
      repository { nameWithOwner }
      reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
  }
]]

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
}

local function ago(iso)
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

--- Open PRs matching `M.queries`, deduped, direct asks first, then most recently updated.
function M.fetch()
  local parts = {}
  for i, q in ipairs(M.queries) do
    parts[#parts + 1] = ("q%d: search(query: %q, type: ISSUE, first: 100) { %s }"):format(i, BASE .. q.q, FIELDS)
  end
  local data = gh.graphql("query {\n  viewer { login }\n" .. table.concat(parts, "\n") .. "\n}", vim.empty_dict())
  local me = data.viewer.login
  local seen, items = {}, {}
  for i, q in ipairs(M.queries) do
    local res = data["q" .. i]
    if res.issueCount > #res.nodes then
      util.notify(("%s: showing %d of %d PRs"):format(q.q, #res.nodes, res.issueCount), vim.log.levels.WARN)
    end
    for _, pr in ipairs(res.nodes) do
      if pr.url and not seen[pr.url] then
        seen[pr.url] = true
        local others = {}
        for _, r in ipairs(pr.reviewRequests and pr.reviewRequests.nodes or {}) do
          local login = r.requestedReviewer and r.requestedReviewer.login
          if login and login ~= me then
            others[#others + 1] = "@" .. login
          end
        end
        local c = pr.commits.nodes[1]
        local ci = c and c.commit.statusCheckRollup and c.commit.statusCheckRollup.state
        items[#items + 1] = {
          rank = i,
          label = q.label,
          label_hl = q.hl,
          repo = pr.repository.nameWithOwner,
          number = pr.number,
          title = pr.title,
          url = pr.url,
          author = pr.author and pr.author.login or "ghost",
          updated = pr.updatedAt,
          ci = ci,
          decision = pr.reviewDecision,
          others = others,
          text = ("%s #%d %s %s %s"):format(
            pr.repository.nameWithOwner,
            pr.number,
            pr.title,
            pr.author and pr.author.login or "",
            q.label
          ),
          preview = {
            ft = "markdown",
            text = ("# %s\n\n%s #%d by @%s · updated %s ago%s\n\n%s"):format(
              pr.title,
              pr.repository.nameWithOwner,
              pr.number,
              pr.author and pr.author.login or "ghost",
              ago(pr.updatedAt),
              #others > 0 and ("\nAlso requested: " .. table.concat(others, ", ")) or "",
              (pr.body or ""):gsub("\r", "")
            ),
          },
        }
      end
    end
  end
  table.sort(items, function(a, b)
    if (a.label == "you") ~= (b.label == "you") then
      return a.label == "you"
    end
    return a.updated > b.updated
  end)
  return items
end

local function format(item)
  local ci = CI[item.ci or ""] or { " ", nil }
  local dec = DECISION[item.decision or ""]
  local ret = {
    { ("%-4s"):format(item.label), item.label_hl },
    { ("%-5s"):format(item.repo:match("/(.+)$")), "Comment" },
    { ("#%-6d"):format(item.number), "SnacksPickerIdx" },
    { ci[1] .. " ", ci[2] },
    { item.title },
    { "  @" .. item.author, "Comment" },
    { " · " .. ago(item.updated), "Comment" },
  }
  if dec then
    ret[#ret + 1] = { " · " .. dec[1], dec[2] }
  end
  if item.label ~= "you" and #item.others > 0 then
    ret[#ret + 1] = { " → " .. table.concat(item.others, " "), "DiagnosticHint" }
  end
  return ret
end

function M.open()
  util.run(function()
    util.notify("Loading PRs waiting on you…")
    local items = M.fetch()
    Snacks.picker({
      title = ("  PRs waiting on you (%d)"):format(#items),
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
  end)
end

return M

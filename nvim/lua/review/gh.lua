-- GitHub access through the `gh` CLI (reuses its auth). Call from inside util.run.
local util = require("review.util")

local M = {}

---@return any
function M.json(args, opts)
  return vim.json.decode(util.sh(vim.list_extend({ "gh" }, args), opts), { luanil = { object = true, array = true } })
end

---@param query string
---@param vars table
function M.graphql(query, vars)
  local r = util.await(function(cb)
    vim.system({ "gh", "api", "graphql", "--input", "-" }, {
      text = true,
      stdin = vim.json.encode({ query = query, variables = vars }),
    }, cb)
  end)
  local ok, data = pcall(vim.json.decode, r.stdout or "", { luanil = { object = true, array = true } })
  local err = ok and data.errors and data.errors[1] and data.errors[1].message
  if r.code ~= 0 or not ok or err then
    local msg = err or vim.trim(r.stderr or "")
    error("GitHub: " .. (msg ~= "" and msg or "request failed"), 0)
  end
  return data.data
end

M.THREADS = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(states: PENDING, first: 1) { nodes { id } }
      reviewDecision
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      files(first: 100) { nodes { path viewerViewedState } }
      reviewThreads(first: 100) {
        nodes {
          path line startLine isResolved isOutdated subjectType
          comments(first: 30) { nodes { author { login } body state } }
        }
      }
    }
  }
}]]

M.ADD_THREAD = [[
mutation($input: AddPullRequestReviewThreadInput!) {
  addPullRequestReviewThread(input: $input) { thread { id } }
}]]

M.MARK_VIEWED = [[
mutation($input: MarkFileAsViewedInput!) {
  markFileAsViewed(input: $input) { clientMutationId }
}]]

M.UNMARK_VIEWED = [[
mutation($input: UnmarkFileAsViewedInput!) {
  unmarkFileAsViewed(input: $input) { clientMutationId }
}]]

M.SUBMIT = [[
mutation($input: SubmitPullRequestReviewInput!) {
  submitPullRequestReview(input: $input) { pullRequestReview { url } }
}]]

M.ADD_REVIEW = [[
mutation($input: AddPullRequestReviewInput!) {
  addPullRequestReview(input: $input) { pullRequestReview { url } }
}]]

return M

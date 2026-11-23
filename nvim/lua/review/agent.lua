-- Agent pre-pass: copilot CLI reviews the PR headlessly in the worktree (read-only tools), and its
-- findings land in the quickfix list and as diagnostics on the lines they refer to. Results are
-- cached per head commit, so reopening a PR is instant.
local util = require("review.util")

local M = {}

---@class review.Finding
---@field path string
---@field lnum integer
---@field kind "bug"|"risk"|"question"
---@field message string

local severity = {
  bug = vim.diagnostic.severity.WARN,
  risk = vim.diagnostic.severity.INFO,
  question = vim.diagnostic.severity.HINT,
}

local PROMPT = [[
You are a senior engineer reviewing pull request #%d "%s" by @%s.
The change is exactly `git diff -w %s HEAD` in this repository (whitespace-only edits are hidden
from the reviewer, so ignore them); run it first. PR description:
<<<
%s
>>>
Read the surrounding code as needed (git show/log/blame, rg, file reads) to judge the impact on
callers and consumers, the invariants in nearby spec.md files, and the AGENTS.md conventions.
Report only what a careful reviewer would raise: bugs, behaviour or compatibility risks, risky logic
without tests, and genuine open questions. No style nits, no praise, no summary.
Output nothing but findings, one per line, at most 15, most important first, in exactly this form:
path/relative/to/repo:LINE: bug|risk|question: one or two sentences
LINE is a line number in the PR's version of the file, on or next to the changed code.
If there are no findings, output exactly: NONE]]

local function cache_file(st)
  return vim.fs.joinpath(
    vim.fn.stdpath("cache"),
    "review",
    "agent",
    ("%s-%s-%d-%s.txt"):format(st.owner, st.name, st.number, st.head)
  )
end

---@return review.Finding[]
function M.parse(text)
  local ret = {}
  for line in vim.gsplit(text, "\n") do
    line = line:gsub("^[%s%-%*`]+", ""):gsub("`", "")
    local path, lnum, kind, msg = line:match("^([^%s:][^:]*):(%d+):%s*(%a+):%s*(.+)$")
    kind = kind and kind:lower()
    if path and severity[kind] then
      ret[#ret + 1] = { path = path, lnum = tonumber(lnum), kind = kind, message = vim.trim(msg) }
    end
  end
  return ret
end

--- Agents sometimes drop the directory; map bare or partial paths back onto the PR's files.
local function resolve(st, findings)
  for _, f in ipairs(findings) do
    if not vim.list_contains(st.files, f.path) then
      for _, file in ipairs(st.files) do
        if vim.endswith(file, "/" .. f.path) then
          f.path = file
          break
        end
      end
    end
  end
  return findings
end

function M.diagnostics(st, rel)
  local ret = {}
  for _, f in ipairs(st.findings or {}) do
    if f.path == rel then
      ret[#ret + 1] = {
        lnum = f.lnum - 1,
        col = 0,
        severity = severity[f.kind],
        source = "copilot",
        message = ("%s: %s"):format(f.kind, f.message),
        user_data = { parts = { { head = "⚑ " .. f.kind, text = f.message } } },
      }
    end
  end
  return ret
end

--- Finding on the given lines, used to prefill a comment.
function M.at(st, rel, l1, l2)
  for _, f in ipairs(st.findings or {}) do
    if f.path == rel and f.lnum >= l1 - 1 and f.lnum <= l2 + 1 then
      return f
    end
  end
end

local function apply(st)
  local items = {}
  for _, f in ipairs(st.findings) do
    items[#items + 1] = {
      filename = vim.fs.joinpath(st.root, f.path),
      lnum = f.lnum,
      text = ("[%s] %s"):format(f.kind, f.message),
      type = f.kind == "bug" and "W" or "I",
    }
  end
  vim.fn.setqflist({}, " ", { title = ("PR #%d agent review"):format(st.number), items = items })
  local review = require("review")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and review.relpath(buf) then
      review.decorate(buf)
    end
  end
  require("review.panel").render()
end

---@param st review.State
---@param opts? {force?: boolean}
function M.start(st, opts)
  local file = cache_file(st)
  if not (opts and opts.force) and vim.uv.fs_stat(file) then
    st.findings = resolve(st, M.parse(table.concat(vim.fn.readfile(file), "\n")))
    return apply(st)
  end
  if vim.fn.executable("copilot") ~= 1 then
    return util.notify("copilot CLI not found; skipping agent review", vim.log.levels.WARN)
  end
  if st.agent_job then
    st.agent_job:kill(15)
  end
  local prompt = PROMPT:format(st.number, st.title, st.author, st.merge_base, st.body:sub(1, 4000))
  local cmd = { "copilot", "-p", prompt, "-s", "--no-ask-user", "--no-color", "--trust-folder" }
  for _, t in ipairs({
    "shell(git diff)",
    "shell(git show)",
    "shell(git log)",
    "shell(git blame)",
    "shell(git grep)",
    "shell(rg)",
    "read",
  }) do
    cmd[#cmd + 1] = "--allow-tool=" .. t
  end
  for _, t in ipairs({ "write", "shell(git push)", "shell(git checkout)", "shell(git reset)", "shell(gh)" }) do
    cmd[#cmd + 1] = "--deny-tool=" .. t
  end
  util.notify(("Agent reviewing PR #%d in the background…"):format(st.number))
  local started = vim.uv.hrtime()
  local job
  job = vim.system(cmd, { cwd = st.root, text = true, timeout = 20 * 60 * 1000 }, function(r)
    vim.schedule(function()
      if st.agent_job ~= job then
        return -- superseded or review closed
      end
      st.agent_job = nil
      if r.code ~= 0 then
        return util.notify(
          ("Agent review failed (%s): %s"):format(r.code, vim.trim(r.stderr or ""):sub(1, 300)),
          vim.log.levels.WARN
        )
      end
      st.findings = resolve(st, M.parse(r.stdout or ""))
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      vim.fn.writefile(vim.split(r.stdout or "", "\n"), file)
      if require("review").active() == st then
        apply(st)
      end
      util.notify(
        ("Agent finished PR #%d in %ds: %d findings (in the review panel)"):format(
          st.number,
          (vim.uv.hrtime() - started) / 1e9,
          #st.findings
        )
      )
    end)
  end)
  st.agent_job = job
end

return M

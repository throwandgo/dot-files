-- Open review threads in a picker: one row each, the whole conversation in the preview.
local M = {}

local function review()
  return require("review")
end

local function strip(body)
  return vim.trim((body or ""):gsub("^`L%d+%-?L?%d*`:%s*", ""))
end

local function login(c)
  local l = c and c.author and c.author.login or "ghost"
  return (l:gsub("^copilot%-pull%-request%-reviewer$", "copilot"))
end

--- Open threads in panel file order: current ones by line, then outdated ones. Threads in `keep`
--- (resolved from the picker) stay listed so X can reopen them.
local function items(st, keep)
  local rank = {}
  for i, f in ipairs(st.files) do
    rank[f] = i
  end
  local ret = {}
  for _, t in ipairs(st.threads or {}) do
    local nodes = t.comments and t.comments.nodes or {}
    if (not t.isResolved or keep[t.id]) and #nodes > 0 then
      local l1 = review().thread_lines(t)
      local lnum = l1 or t.originalLine
      local text = {}
      for _, c in ipairs(nodes) do
        text[#text + 1] = ("**@%s** · %s ago%s\n\n%s\n"):format(
          login(c),
          c.createdAt and require("review.inbox").ago(c.createdAt) or "?",
          c.state == "PENDING" and " · _pending_" or "",
          strip(c.body)
        )
      end
      local where = ("%s:%s"):format(t.path, lnum or "file")
      ret[#ret + 1] = {
        thread = t,
        file = t.path,
        lnum = lnum,
        outdated = t.isOutdated or not l1,
        resolved = t.isResolved,
        pending = nodes[1].state == "PENDING",
        replies = #nodes - 1,
        author = login(nodes[1]),
        last = login(nodes[#nodes]),
        summary = strip(nodes[1].body):gsub("%s+", " "),
        rank = rank[t.path] or math.huge,
        text = ("%s %s %s"):format(login(nodes[1]), where, strip(nodes[1].body)),
        preview = {
          ft = "markdown",
          text = ("# %s:%s%s\n\n`%s`\n\n%s"):format(
            vim.fs.basename(t.path),
            lnum or "file",
            (t.isResolved and " · resolved" or "")
              .. ((t.isOutdated or not l1) and " · outdated (the code has changed since)" or ""),
            t.path,
            table.concat(text, "\n---\n\n")
          ),
        },
      }
    end
  end
  table.sort(ret, function(a, b)
    if a.outdated ~= b.outdated then
      return b.outdated
    elseif a.rank ~= b.rank then
      return a.rank < b.rank
    end
    return (a.lnum or 0) < (b.lnum or 0)
  end)
  return ret
end

local function format(item)
  return {
    item.resolved and { "✓ ", "DiagnosticOk" } or {
      item.pending and "✎ " or item.outdated and "◌ " or "● ",
      item.outdated and "Comment" or "DiagnosticInfo",
    },
    { ("@%-14s "):format(#item.author > 14 and item.author:sub(1, 13) .. "…" or item.author), "Title" },
    { ("%s:%s "):format(vim.fs.basename(item.file), item.lnum or "file"), "Comment" },
    { item.replies > 0 and ("(%d ↳ @%s) "):format(item.replies, item.last) or "", "DiagnosticHint" },
    { item.summary, item.resolved and "Comment" or nil },
  }
end

--- Close the picker, then run `fn(thread)` (reply / resolve / delete open their own UI).
local function on_thread(fn)
  return function(picker, item)
    picker:close()
    if item then
      fn(item.thread)
    end
  end
end

local function title(list)
  local open, outdated = 0, 0
  for _, i in ipairs(list) do
    open, outdated = open + (i.resolved and 0 or 1), outdated + (not i.resolved and i.outdated and 1 or 0)
  end
  return ("Threads · %d open%s · R reply  X resolve/reopen  D delete pending"):format(
    open,
    outdated > 0 and (" (%d outdated)"):format(outdated) or ""
  )
end

function M.open()
  local util = require("review.util")
  local st = review().active()
  if not st then
    return util.notify("No active review", vim.log.levels.WARN)
  end
  local keep = {}
  if #items(st, keep) == 0 then
    return util.notify("No open comment threads")
  end
  Snacks.picker({
    title = title(items(st, keep)),
    finder = function()
      return items(review().active() or st, keep)
    end,
    format = format,
    preview = "preview",
    focus = "list",
    sort = { fields = { "score:desc", "idx" } },
    matcher = { sort_empty = false },
    confirm = function(picker, item)
      picker:close()
      if item then
        require("review.panel").open(item.file, item.lnum)
      end
    end,
    actions = {
      thread_reply = on_thread(review().reply),
      -- resolving needs no input, so the picker stays open and re-lists
      thread_resolve = function(picker, item)
        if not item then
          return
        end
        keep[item.thread.id] = true
        review().toggle_resolved(item.thread, function()
          if not picker.closed then
            picker.title = title(items(review().active() or st, keep))
            picker:refresh()
          end
        end)
      end,
      thread_delete = on_thread(review().delete_pending),
    },
    win = {
      preview = { wo = { wrap = true, linebreak = true } },
      list = {
        keys = {
          R = { "thread_reply", desc = "Reply" },
          X = { "thread_resolve", desc = "Resolve / reopen" },
          D = { "thread_delete", desc = "Delete pending comment" },
        },
      },
    },
  })
end

return M

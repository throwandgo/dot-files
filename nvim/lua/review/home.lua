-- Homepage (snacks dashboard): a roadrunner, then launchers for my PRs, PRs waiting on my review
-- and a plain agent session. Queue sizes come from a disk cache so the page paints instantly; a
-- count-only search refreshes them in the background.
local inbox = require("review.inbox")
local util = require("review.util")

local M = {}

local CACHE = vim.fs.joinpath(vim.fn.stdpath("cache"), "review", "home.json")
local STALE = 60 -- seconds

-- every line is the same width: snacks centers each header line on its own
M.LOGO = [[
                                                        _               
                                                      _/*`\             
                                                     /'++++`\           
                                                     |=======`\         
                                                     |::::(@)::`-------.
                                                     |:::::\___________\
                                                     |::::/             
                                        ___..----''''''**/              
 __________________________..---''''''''****************/               
<@@@@@@@@@@@@@@@@@@@@@@@%%%###***++++++++++++++++++++++/                
 `--------==========----.%#***+===--------------------/                 
                         \#**+==--:::::::::::::::::::/                  
                          `.________________________/                   
                              \:::::/   \:::::::/                       
                               \:::/     \::::/                         
                                /:/       \::/                          
                                \:\       |:|                           
                                 \:|      (::`--------.                 
                                  |:|      `------.::::\                
                                  \:\            /:/\    `~.            
                                   \_\          /_/  \_    )            
                                `~--'  `=~                              ]]

---@type { counts?: { mine: integer, you: integer, team: integer }, at?: integer, error?: string }
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

--- Re-count the queues unless fresh or already counting; repaints when done.
function M.refresh(force)
  if loading or (not force and M.data.at and os.time() - M.data.at < STALE) then
    return
  end
  loading = true
  util.run(function()
    local ok, res = pcall(inbox.counts)
    loading = false
    M.data.at = os.time()
    M.data.counts = ok and res or M.data.counts
    M.data.error = not ok and tostring(res) or nil
    save()
    Snacks.dashboard.update()
  end)
end

-- Colour roles on the launchers: bold names, each count in its queue's accent (shared with the
-- icon), plain units, dim separators and an italic 7d window.
local HL = { label = "Title", unit = "Normal", sep = "NonText", window = "Comment" }
local ACCENT = { mine = "Statement", you = "DiagnosticWarn", team = "DiagnosticHint", agent = "String" }

--- Chunks after a launcher's name: counts (or loading / error), then the dimmed 7d window.
local function detail(parts)
  if M.data.error then
    return { { M.data.error:gsub("\n.*", ""), hl = "DiagnosticError" } }
  end
  local c = M.data.counts
  if not c then
    return { { loading and "counting…" or "", hl = HL.window } }
  end
  local out = {}
  for i, p in ipairs(parts(c)) do
    if i > 1 then
      out[#out + 1] = { " · ", hl = HL.sep }
    end
    out[#out + 1] = { tostring(p[1]), hl = p[2] }
    out[#out + 1] = { " " .. p[3], hl = HL.unit }
  end
  out[#out + 1] = { "  " .. inbox.WINDOW, hl = HL.window }
  return out
end

--- Dashboard section: the PR launchers and the agent.
function M.launchers()
  M.refresh()
  local function item(icon, accent, key, name, extra)
    local desc = { { ("%-17s"):format(name), hl = HL.label } }
    vim.list_extend(desc, extra)
    return { icon = { icon, hl = accent, width = 2 }, key = key, desc = desc }
  end
  local mine = item(
    "\u{f407}",
    ACCENT.mine,
    "p",
    "My PRs",
    detail(function(c)
      return { { c.mine, ACCENT.mine, "open" } }
    end)
  )
  local reviews = item(
    "\u{f441}",
    ACCENT.you,
    "r",
    "Reviews waiting",
    detail(function(c)
      return { { c.you, ACCENT.you, "for you" }, { c.team, ACCENT.team, "more for LNE" } }
    end)
  )
  local agent = item("\u{f4b8}", ACCENT.agent, "a", "Agent session", { { "copilot", hl = ACCENT.agent } })
  mine.action, reviews.action, agent.action = inbox.open_mine, inbox.open, M.agent
  return { padding = 1, mine, reviews, agent }
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

return M

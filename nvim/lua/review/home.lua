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

--- "6 open  (active in last 7d)" style detail after a launcher's name.
local function detail(text)
  local c = M.data.counts
  if M.data.error then
    return { "  " .. M.data.error:gsub("\n.*", ""), "DiagnosticError" }
  end
  return { "  " .. (c and text(c) or loading and "counting…" or "") .. "  (" .. inbox.WINDOW .. ")", "Comment" }
end

--- Dashboard section: the PR launchers and the agent.
function M.launchers()
  M.refresh()
  local function item(icon, key, name, action, info)
    local desc = { { name, "SnacksDashboardDesc" } }
    if info then
      desc[#desc + 1] = detail(info)
    end
    return { icon = icon, key = key, desc = desc, action = action }
  end
  return {
    padding = 1,
    item(" ", "p", "My PRs", inbox.open_mine, function(c)
      return ("%d open"):format(c.mine)
    end),
    item(" ", "r", "Reviews waiting", inbox.open, function(c)
      return ("%d for you · %d more for LNE"):format(c.you, c.team)
    end),
    item(" ", "a", "Agent session (copilot)", M.agent),
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

return M

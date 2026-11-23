-- Indexed grep: zoekt (home/zoekt.nix) answers from an in-memory trigram index in a few ms, where rg
-- pays ~0.5s per query because endpoint security intercepts every file open. zoekt indexes each
-- repo's committed HEAD, so files that differ from the indexed commit (edits, other branches,
-- worktrees, untracked files) form an "overlay": their zoekt hits are dropped and rg searches them
-- instead. Without a server, an indexed repo, or with a huge overlay, this falls back to plain rg.
--
-- Picker input: a regex (smart case), optionally followed by ` -- ` and raw zoekt terms that scope
-- it, e.g. `def apply -- f:\.scala$ -f:test` or `Foo -- lang:java`.
local M = {}

local uv = vim.uv
local OVERLAY_MAX = 3000
local TIMEOUT_MS = 5000
local LUANIL = { luanil = { object = true, array = true } }

---@class search.zoekt.Root
---@field root string worktree root
---@field repo? string zoekt repo name
---@field sha? string indexed commit
---@field changed? table<string, true> repo-relative paths that differ from `sha`
---@field files? string[] existing absolute paths of `changed`
---@field fallback? string why this root can't use zoekt
---@field ready? boolean
---@field refreshing? boolean
---@field waiters fun()[]

---@type table<string, search.zoekt.Root>
local roots = {}

function M.url()
  return vim.g.zoekt_url or "127.0.0.1:6070"
end

--- Minimal HTTP/1.0 client over a uv TCP socket: no process spawn per keystroke, and HTTP/1.0
--- makes the server close the connection instead of using chunked encoding.
---@param path string
---@param body table
---@param cb fun(err?: string, status?: integer, body?: string)
---@return fun() cancel
function M.post(path, body, cb)
  local host, port = M.url():match("^([^:]+):(%d+)$")
  local data = vim.json.encode(body)
  local tcp, timer = uv.new_tcp(), uv.new_timer()
  local chunks, done = {}, false
  local function finish(err, status, resp)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    if not tcp:is_closing() then
      tcp:close()
    end
    cb(err, status, resp)
  end
  timer:start(TIMEOUT_MS, 0, function()
    finish("timeout")
  end)
  tcp:connect(host, tonumber(port), function(err)
    if err then
      return finish(err)
    end
    tcp:write(
      ("POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"):format(
        path,
        host,
        #data,
        data
      )
    )
    tcp:read_start(function(rerr, chunk)
      if rerr then
        return finish(rerr)
      elseif chunk then
        chunks[#chunks + 1] = chunk
        return
      end
      local resp = table.concat(chunks)
      local sep = resp:find("\r\n\r\n", 1, true)
      finish(nil, tonumber(resp:match("^HTTP/%d%.%d (%d+)")), sep and resp:sub(sep + 4) or "")
    end)
  end)
  return function()
    finish("cancelled")
  end
end

--- Blocking variant for health checks and tests.
---@return string? err, integer? status, table? json
function M.post_sync(path, body, timeout)
  local res
  M.post(path, body, function(...)
    res = { ... }
  end)
  vim.wait(timeout or TIMEOUT_MS, function()
    return res ~= nil
  end, 5)
  if not res then
    return "timeout"
  end
  local ok, json = pcall(vim.json.decode, res[3] or "", LUANIL)
  return res[1], res[2], ok and json or nil
end

--- Runs `start(done)` and suspends the snacks async context until `done` is called.
---@async
local function await(async, start)
  local res
  local cancel = start(function(...)
    res = { ... }
    vim.schedule(function()
      async:resume()
    end)
  end)
  if cancel then
    async:on("abort", cancel)
  end
  while not res do
    async:suspend()
  end
  return unpack(res)
end

---@param s string
function M.escape(s)
  return (s:gsub("[%^%$%(%)%.%[%]%*%+%?%{%}%|\\]", "\\%0"))
end

--- A regex as a single zoekt term; unquoted words would be ANDed.
---@param re string
function M.quote(re)
  return '"' .. re:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function git(root, args, cb)
  vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }, function(r)
    cb(r.code == 0 and r.stdout or nil)
  end)
end

local function lines(s)
  return s and vim.split(s, "\n", { trimempty = true }) or {}
end

---@param state search.zoekt.Root
---@param reason? string
local function settle(state, reason)
  state.fallback, state.ready, state.refreshing = reason, true, false
  local waiters = state.waiters
  state.waiters = {}
  vim.schedule(function()
    for _, w in ipairs(waiters) do
      w()
    end
  end)
end

--- Recomputes which files differ from the indexed commit. Async; searches keep using the previous
--- overlay meanwhile, only the first search of a root waits for it.
---@param state search.zoekt.Root
function M.refresh(state)
  if state.refreshing then
    return
  end
  state.refreshing = true
  git(state.root, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, function(common)
    local source = common and vim.fs.dirname(vim.trim(common))
    M.post("/api/list", { Q = "" }, function(err, status, body)
      local ok, list = pcall(vim.json.decode, body or "", LUANIL)
      if err or status ~= 200 or not ok then
        return settle(state, "zoekt server unreachable at " .. M.url())
      end
      local repo
      for _, r in ipairs(vim.tbl_get(list, "List", "Repos") or {}) do
        if r.Repository.Source == source then
          repo = r.Repository
        end
      end
      if not repo then
        return settle(state, "repo not indexed: " .. tostring(source))
      end
      local sha = repo.Branches[1].Version
      local pending, diff, untracked = 2, nil, nil
      local function join()
        pending = pending - 1
        if pending > 0 then
          return
        end
        if not diff then
          return settle(state, "indexed commit " .. sha:sub(1, 8) .. " not in this checkout")
        end
        local changed, files = {}, {}
        for _, list_ in ipairs({ lines(diff), lines(untracked) }) do
          for _, rel in ipairs(list_) do
            -- a trailing "/" marks a nested repository, which the index doesn't cover either
            if not changed[rel] and rel:sub(-1) ~= "/" then
              changed[rel] = true
              local abs = state.root .. "/" .. rel
              if uv.fs_stat(abs) then
                files[#files + 1] = abs
              end
            end
          end
        end
        state.repo, state.sha, state.changed, state.files = repo.Name, sha, changed, files
        settle(state, #files > OVERLAY_MAX and ("%d files differ from the index"):format(#files) or nil)
      end
      git(state.root, { "diff", "--name-only", "--no-renames", sha }, function(out)
        diff = out
        join()
      end)
      git(state.root, { "ls-files", "--others", "--exclude-standard" }, function(out)
        untracked = out or ""
        join()
      end)
    end)
  end)
end

---@param path? string
---@return search.zoekt.Root?
function M.root(path)
  path = path and path ~= "" and path or uv.cwd()
  local root = vim.fs.root(path, ".git")
  if not root then
    return
  end
  roots[root] = roots[root] or { root = root, waiters = {} }
  return roots[root]
end

--- Files written since the last refresh differ from the index too; keep the overlay exact without
--- rerunning git.
function M.track_write(path)
  local state = path and M.root(vim.fs.dirname(path))
  if not (state and state.changed) then
    return
  end
  local rel = path:sub(#state.root + 2)
  if not state.changed[rel] then
    state.changed[rel] = true
    table.insert(state.files, path)
  end
end

---@param terms string raw zoekt terms after ` -- `
---@return fun(rel: string): boolean
local function path_filter(terms)
  local inc, exc = {}, {}
  for _, t in ipairs(vim.split(terms, "%s+", { trimempty = true })) do
    local neg, re = t:match("^(%-?)f:(.+)$")
    if not re then
      neg, re = t:match("^(%-?)file:(.+)$")
    end
    local ok, rx = pcall(vim.regex, "\\v" .. (re or ""))
    if re and ok then
      table.insert(neg == "-" and exc or inc, rx)
    end
  end
  return function(rel)
    for _, rx in ipairs(exc) do
      if rx:match_str(rel) then
        return false
      end
    end
    for _, rx in ipairs(inc) do
      if not rx:match_str(rel) then
        return false
      end
    end
    return true
  end
end

--- Converts zoekt file matches into snacks grep items.
---@param res table zoekt `Result`
---@param state search.zoekt.Root
---@param cb fun(item: snacks.picker.finder.Item)
---@param symbols? boolean
local function emit(res, state, cb, symbols)
  for _, f in ipairs(res.Files or {}) do
    if not state.changed[f.FileName] then
      for _, lm in ipairs(f.LineMatches or {}) do
        if not lm.FileName then
          local text = vim.base64.decode(lm.Line):gsub("\r?\n$", "")
          local frag = lm.LineFragments[1]
          local col = frag and frag.LineOffset or 0
          local positions = {}
          for _, fr in ipairs(lm.LineFragments) do
            for i = fr.LineOffset + 1, fr.LineOffset + fr.MatchLength do
              positions[#positions + 1] = i
            end
          end
          local sym = symbols and frag and frag.SymbolInfo
          cb({
            text = (sym and sym.Sym .. " " or "") .. f.FileName .. ":" .. text,
            file = f.FileName,
            cwd = state.root,
            pos = { lm.LineNumber, col },
            end_pos = frag and { lm.LineNumber, col + frag.MatchLength } or nil,
            line = text,
            positions = positions,
            comment = sym and sym.Kind or nil,
          })
        end
      end
    end
  end
end

local function search_body(q, max)
  return {
    Q = q,
    Opts = {
      ShardMaxMatchCount = 100000,
      TotalMaxMatchCount = 100000,
      MaxDocDisplayCount = max,
      MaxMatchDisplayCount = max * 5,
      NumContextLines = 0,
    },
  }
end

---@class search.zoekt.Opts: snacks.picker.grep.Config
---@field word? boolean whole word, case-sensitive
---@field symbols? boolean match symbol definitions only

---@param opts search.zoekt.Opts
---@type snacks.picker.finder
function M.finder(opts, ctx)
  local search = ctx.filter.search
  if search == "" then
    return function() end
  end
  local grep = require("snacks.picker.source.grep").grep
  local state = M.root(opts.cwd)
  if not state then
    return grep(opts, ctx)
  end
  local pattern, args = Snacks.picker.util.parse(search)
  local terms = table.concat(args, " ")
  local max = opts.symbols and 500 or 20000

  ---@async
  return function(cb)
    local async = ctx.async
    if not state.ready then
      M.refresh(state)
      await(async, function(done)
        table.insert(state.waiters, done)
      end)
    end
    local function rg()
      return grep(vim.tbl_extend("force", opts, { cwd = state.root }), ctx)(cb)
    end
    if state.fallback then
      return rg()
    end

    local literal = opts.word or opts.regex == false
    local function query(lit)
      local re = lit and M.escape(pattern) or pattern
      re = opts.word and ("\\b" .. re .. "\\b") or re
      return ("r:%s %s%s%s %s"):format(
        M.quote("^" .. M.escape(state.repo) .. "$"),
        opts.word and "case:yes " or "",
        opts.symbols and "sym:" or "",
        M.quote(re),
        terms
      )
    end
    local function run(lit)
      return await(async, function(done)
        return M.post("/api/search", search_body(query(lit), max), done)
      end)
    end
    local err, status, body = run(literal)
    if status == 400 and not literal then -- not a valid regex: search it literally, like rg -F
      literal = true
      err, status, body = run(true)
    end
    local ok, json = pcall(vim.json.decode, body or "", LUANIL)
    if err or status ~= 200 or not ok then
      return rg()
    end
    local res = json.Result or {}
    if res.Files and res.Files[1] and res.Files[1].Version ~= state.sha then
      vim.schedule(function() -- the index moved on; recompute the overlay for the next query
        M.refresh(state)
      end)
    end
    emit(res, state, cb, opts.symbols)

    if opts.symbols then
      return
    end
    local keep = path_filter(terms)
    local files = vim.tbl_filter(function(abs)
      return keep(abs:sub(#state.root + 2))
    end, state.files)
    if #files == 0 then
      return
    end
    -- rg over the overlay files only, reusing snacks' rg output parsing
    local filter = setmetatable({ search = pattern }, { __index = ctx.filter })
    local overlay_ctx = setmetatable({ filter = filter }, { __index = ctx })
    grep(
      vim.tbl_extend("force", opts, {
        cwd = state.root,
        dirs = files,
        regex = not literal,
        args = opts.word and { "--word-regexp" } or opts.args,
      }),
      overlay_ctx
    )(function(item)
      local prefix = state.root .. "/"
      if item.file:sub(1, #prefix) == prefix then
        item.file = item.file:sub(#prefix + 1)
      end
      item.cwd = state.root
      cb(item)
    end)
  end
end

local function cwd()
  local file = vim.api.nvim_buf_get_name(0)
  return vim.fn.filereadable(file) == 1 and vim.fs.dirname(file) or uv.cwd()
end

---@param opts? search.zoekt.Opts
function M.grep(opts)
  opts = vim.tbl_deep_extend("force", {
    source = "zoekt",
    title = "Grep (zoekt)",
    finder = M.finder,
    format = "file",
    regex = true,
    live = true,
    supports_live = true,
    show_empty = true,
    cwd = cwd(),
  }, opts or {})
  local state = M.root(opts.cwd)
  if state and state.ready then
    M.refresh(state)
  end
  return Snacks.picker.pick(opts)
end

--- Word under cursor (whole word, case-sensitive) or the visual selection (literal).
function M.grep_word()
  local visual = Snacks.picker.util.visual()
  if visual then
    return M.grep({ title = "Selection (zoekt)", search = visual.text, regex = false, live = false })
  end
  return M.grep({ title = "Word (zoekt)", search = vim.fn.expand("<cword>"), word = true, live = false })
end

--- Definitions across the whole repo and every language (ctags); LSP workspace symbols only cover
--- the current build.
function M.symbols()
  return M.grep({ title = "Symbols (zoekt)", symbols = true })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("search_zoekt", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      M.track_write(vim.api.nvim_buf_get_name(ev.buf))
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      for _, state in pairs(roots) do
        M.refresh(state)
      end
    end,
  })
  -- the first overlay takes ~0.5s (git ls-files under endpoint security); don't make a search wait
  vim.defer_fn(function()
    local state = M.root(uv.cwd())
    if state then
      M.refresh(state)
    end
  end, 1000)
end

M._roots = roots
return M

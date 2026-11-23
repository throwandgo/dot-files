-- Maps read-only dependency sources (Metals' extracted sources jars, jdtls jdt:// class files) to
-- the editable file in this repo, for libraries built from the monorepo itself (core-*, mantle).
local M = {}

---@class understand.Dependency
---@field jar string jar file name
---@field rel string path inside the jar
---@field any_ext? boolean rel ends in .java but the source may be .scala (compiled class)

---@param name string buffer name
---@return understand.Dependency?
function M.parse(name)
  local jar, rel = name:match("/%.metals/readonly/dependencies/([^/]+)/(.+)$")
  if jar then
    return { jar = jar, rel = rel }
  end
  if vim.startswith(name, "jdt://") then
    -- jdt://contents/<jar>/<package>/<Class>.class?=<project>/<encoded jar path>...
    local jar2, pkg, cls = vim.uri_decode(name):match("^jdt://contents/([^/]+)/([^/]+)/([^/?]+)%.class")
    if jar2 then
      return { jar = jar2, rel = pkg:gsub("%.", "/") .. "/" .. cls:gsub("%$.*", "") .. ".java", any_ext = true }
    end
  end
end

---@param jar string
---@return string? version
function M.version(jar)
  return jar:match("%-(%d[%w%.%-]-)%-sources%.jar$") or jar:match("%-(%d[%w%.%-]-)%.jar$")
end

-- "core-grpc_2.13-5.5.0-sources.jar" -> { "core", "grpc" }
local function artifact_words(jar)
  local artifact = jar:gsub("%-sources%.jar$", ""):gsub("%.jar$", ""):gsub("%-%d.*$", ""):gsub("_%d[%d%.]*$", "")
  return vim.split(artifact, "[-_]", { trimempty = true })
end

---@param dep understand.Dependency
---@param root string git root
---@return string[] absolute paths, best match first
function M.candidates(dep, root)
  local pathspecs = { "*/" .. dep.rel }
  if dep.any_ext then
    local stem = dep.rel:gsub("%.java$", "")
    pathspecs = { "*/" .. stem .. ".java", "*/" .. stem .. ".scala" }
  end
  local res = vim.system({ "git", "ls-files", "--", unpack(pathspecs) }, { cwd = root, text = true }):wait()
  local files = vim.split(res.stdout or "", "\n", { trimempty = true })

  -- Several builds can vendor the same package; prefer the module named like the artifact.
  local words = artifact_words(dep.jar)
  local function score(path)
    local s = 0
    for _, w in ipairs(words) do
      if
        path:find("/" .. w .. "/", 1, true)
        or path:find("/" .. w .. "-", 1, true)
        or vim.startswith(path, w .. "/")
      then
        s = s + 1
      end
    end
    -- Main sources over tests and copies under docs/examples.
    return s + (path:find("/src/main/", 1, true) and 0.5 or 0)
  end
  table.sort(files, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then
      return sa > sb
    end
    return a < b
  end)
  return vim.tbl_map(function(f)
    return root .. "/" .. f
  end, files)
end

-- Repo of the dependency buffer (Metals' readonly dir lives inside it) or of the cwd (jdt://).
local function repo_root(name)
  local dir = vim.startswith(name, "jdt://") and vim.fn.getcwd() or vim.fs.dirname(name)
  return vim.fs.root(dir, ".git")
end

---@param buf? integer
---@return string[] candidates, understand.Dependency? dep
function M.find(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  local dep = M.parse(name)
  local root = dep and repo_root(name)
  if not (dep and root) then
    return {}, dep
  end
  return M.candidates(dep, root), dep
end

-- Puts the cursor on the same code in the local copy, which may have drifted from the jar.
local function place_cursor(from)
  local cur = vim.api.nvim_buf_get_lines(0, from.lnum - 1, from.lnum, false)[1]
  if cur and from.line ~= "" and vim.trim(cur) == from.line then
    vim.api.nvim_win_set_cursor(0, { from.lnum, 0 })
  elseif
    not (from.line ~= "" and vim.fn.search("\\V" .. vim.fn.escape(from.line, "\\"), "cw") > 0)
    and not (from.word ~= "" and vim.fn.search("\\<" .. vim.fn.escape(from.word, "\\") .. "\\>", "cw") > 0)
  then
    return
  end
  vim.cmd("normal! ^zz")
end

local function open(path, dep, from)
  vim.cmd.edit(vim.fn.fnameescape(path))
  place_cursor(from)
  local version = M.version(dep.jar)
  vim.notify(
    ("Opened the local source of %s.%s"):format(
      dep.jar,
      version and (" The dependency is %s; this is your checkout and may differ."):format(version) or ""
    ),
    vim.log.levels.INFO,
    { title = "Local source" }
  )
end

function M.jump()
  local candidates, dep = M.find(0)
  if not dep then
    vim.notify("Not a dependency source (.metals/readonly or jdt://)", vim.log.levels.WARN, { title = "Local source" })
    return
  end
  if #candidates == 0 then
    vim.notify(("No file in this repo matches %s"):format(dep.rel), vim.log.levels.WARN, { title = "Local source" })
    return
  end
  local from = {
    lnum = vim.api.nvim_win_get_cursor(0)[1],
    line = vim.trim(vim.api.nvim_get_current_line()),
    word = vim.fn.expand("<cword>"),
  }
  if #candidates == 1 then
    return open(candidates[1], dep, from)
  end
  vim.ui.select(candidates, {
    prompt = "Local source",
    format_item = function(p)
      return vim.fn.fnamemodify(p, ":~:.")
    end,
  }, function(choice)
    if choice then
      open(choice, dep, from)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = vim.api.nvim_create_augroup("understand_local_source", { clear = true }),
    pattern = { "*/.metals/readonly/dependencies/*", "jdt://*" },
    callback = function(ev)
      if vim.b[ev.buf].local_source_offered then
        return
      end
      vim.b[ev.buf].local_source_offered = true
      local candidates = M.find(ev.buf)
      if #candidates > 0 then
        vim.notify(
          ("Editable in this repo: %s  (gas)"):format(vim.fn.fnamemodify(candidates[1], ":~:.")),
          vim.log.levels.INFO,
          { title = "Local source" }
        )
      end
    end,
  })
end

return M

-- Finds the build that owns a file in a monorepo with many nested sbt and Gradle builds.
--
-- Marker-based detection (nearest `build.sbt`, `.git`, ...) picks sbt subprojects such as
-- `finance/payment/payment-service`, or the repo root, instead of the build that aggregates them.
-- Each wrong root becomes its own Metals/jdtls server that can't import anything.
local M = {}

local uv = vim.uv

local function is_file(p)
  local s = uv.fs_stat(p)
  return s ~= nil and s.type == "file"
end

local function read(p)
  local f = io.open(p, "r")
  if not f then
    return ""
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- sbt writes `project/build.properties` into any directory it runs in, so only a meta-build
-- (`project/plugins.sbt` or `project/*.scala`) marks a real build.
function M.is_sbt_root(dir)
  if not is_file(dir .. "/build.sbt") then
    return false
  end
  if is_file(dir .. "/project/plugins.sbt") then
    return true
  end
  for name, kind in vim.fs.dir(dir .. "/project") do
    if kind == "file" and name:match("%.scala$") then
      return true
    end
  end
  return false
end

function M.is_gradle_root(dir)
  return is_file(dir .. "/settings.gradle") or is_file(dir .. "/settings.gradle.kts")
end

function M.is_maven_root(dir)
  return is_file(dir .. "/mvnw") or is_file(dir .. "/pom.xml")
end

-- True when an sbt build at `parent` declares `child` as one of its projects, e.g.
-- `project in file("./payment/payment-service")`.
local function sbt_aggregates(parent, child)
  local rel = child:sub(#parent + 2)
  for name, kind in vim.fs.dir(parent) do
    if kind == "file" and name:match("%.sbt$") then
      for ref in read(parent .. "/" .. name):gmatch('file%(%s*"([^"]+)"%s*%)') do
        ref = ref:gsub("^%./", ""):gsub("/$", "")
        if ref == rel then
          return true
        end
      end
    end
  end
  return false
end

-- Directories from the file's directory up to (and including) the git root, or up to $HOME.
local function ancestors(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local start = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local stop = vim.fs.root(start, ".git") or vim.env.HOME
  local dirs = {}
  local dir = start
  while dir and #dir >= #stop do
    table.insert(dirs, dir)
    if dir == stop then
      break
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return dirs
end

---@param path string file or directory
---@param kinds { sbt?: boolean, gradle?: boolean, maven?: boolean }
---@return string|nil root innermost build of the requested kinds, widened to an aggregating sbt build
function M.find(path, kinds)
  local dirs = ancestors(path)
  for i, dir in ipairs(dirs) do
    local sbt = kinds.sbt and M.is_sbt_root(dir)
    if sbt or (kinds.gradle and M.is_gradle_root(dir)) or (kinds.maven and M.is_maven_root(dir)) then
      local root = dir
      if sbt then
        for j = i + 1, #dirs do
          if M.is_sbt_root(dirs[j]) and sbt_aggregates(dirs[j], root) then
            root = dirs[j]
          end
        end
      end
      return root
    end
  end
end

return M

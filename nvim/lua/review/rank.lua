-- Review order: the code that does the work first, then the tests that pin it, then the build and
-- config around it, then the prose. Within a group files keep git's path order, so a package's
-- files stay together.
local M = {}

M.GROUPS = { "Code", "Tests", "Build & config", "Docs" }

local DOC_EXT = { md = true, mdx = true, rst = true, adoc = true }

local TEST_NAME = {
  "Spec%.scala$",
  "Test%.scala$",
  "Suite%.scala$",
  "IT%.scala$",
  "Test%.java$",
  "Tests%.java$",
  "IT%.java$",
  "Test%.kt$",
  "_test%.go$",
  "_test%.sh$",
  "_test%.py$",
  "^test_.*%.py$",
  "%.test%.[jt]sx?$",
  "%.spec%.[jt]sx?$",
}

local TEST_DIR = { "/src/test/", "/src/it/", "/__tests__/", "/tests?/", "/testdata/", "/fixtures/" }

local BUILD_NAME = {
  "%.sbt$",
  "^build%.properties$",
  "^Dockerfile",
  "%.[Dd]ockerfile$",
  "^docker%-compose",
  "^compose%.ya?ml$",
  "^Makefile$",
  "%.mk$",
  "%.gradle$",
  "%.gradle%.kts$",
  "^gradle%.properties$",
  "^gradlew",
  "^pom%.xml$",
  "^package%.json$",
  "^go%.mod$",
  "^go%.sum$",
  "^pyproject%.toml$",
  "^requirements.*%.txt$",
  "%.lock$",
  "%-lock%.json$",
  "^CODEOWNERS$",
  "^%.",
}

local BUILD_EXT = {
  yaml = true,
  yml = true,
  json = true,
  toml = true,
  conf = true,
  hocon = true,
  properties = true,
  ini = true,
  env = true,
  xml = true,
  tf = true,
  tfvars = true,
  nix = true,
  cfg = true,
}

local BUILD_DIR = { "^%.github/", "/%.github/", "^project/", "/project/", "^helm/", "/helm/", "/k8s/", "^k8s/" }

local function any(s, patterns)
  for _, p in ipairs(patterns) do
    if s:find(p) then
      return true
    end
  end
  return false
end

--- 1 code, 2 tests, 3 build & config, 4 docs.
---@param path string repo-relative
---@return integer
function M.group(path)
  local name = vim.fs.basename(path)
  local ext = (name:match("%.([^.]+)$") or ""):lower()
  if DOC_EXT[ext] then
    return 4
  end
  if any(name, TEST_NAME) or any("/" .. path, TEST_DIR) then
    return 2
  end
  if BUILD_EXT[ext] or any(name, BUILD_NAME) or any(path, BUILD_DIR) then
    return 3
  end
  return 1
end

---@param files string[]
---@return string[] files ordered by group, stable within a group
function M.sort(files)
  local idx = {}
  for i, f in ipairs(files) do
    idx[f] = i
  end
  local out = vim.list_slice(files)
  table.sort(out, function(a, b)
    local ga, gb = M.group(a), M.group(b)
    if ga ~= gb then
      return ga < gb
    end
    return idx[a] < idx[b]
  end)
  return out
end

return M

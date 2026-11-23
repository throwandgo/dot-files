-- Java versions involved in running jdtls.
local M = {}

-- Provided by home-manager (home/base.nix).
M.jdtls_jdk = vim.fn.expand("~/.local/share/jdtls-jdk")
M.jdtls_java = M.jdtls_jdk .. "/bin/java"
M.nix_hint =
  "bump `jdkNN_headless` for .local/share/jdtls-jdk in ~/.config/home-manager/home/base.nix and run home-manager switch"

-- Basenames collide across the repo (several build-logic/ and java/ roots), which would make
-- unrelated projects share one jdtls workspace.
---@return string|nil
function M.jdtls_project_name(root_dir)
  return root_dir and (vim.fn.fnamemodify(root_dir, ":~"):gsub("^~/", ""):gsub("[/~]", "_"))
end

---@return integer|nil
function M.major(home)
  local f = home and io.open(home .. "/release", "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  local v = s:match('JAVA_VERSION="([%d.]+)')
  return v and tonumber(v:match("^1%.(%d+)") or v:match("^(%d+)"))
end

-- JDK used for project builds and Gradle imports (matches the CLI).
---@return string|nil
function M.project_jdk()
  if vim.env.JAVA_HOME and vim.env.JAVA_HOME ~= "" then
    return vim.env.JAVA_HOME
  end
  if vim.fn.executable("/usr/libexec/java_home") == 1 then
    local home = vim.trim(vim.fn.system({ "/usr/libexec/java_home" }))
    if vim.v.shell_error == 0 then
      return home
    end
  end
end

---@return string|nil
function M.jdtls_version()
  local f = io.open(vim.fn.stdpath("data") .. "/mason/packages/jdtls/mason-receipt.json", "r")
  if not f then
    return nil
  end
  local ok, receipt = pcall(vim.json.decode, f:read("*a"))
  f:close()
  local id = ok and vim.tbl_get(receipt, "source", "id") or ""
  return id:match("@v?([%w.%-]+)$")
end

-- jdtls' wrapper only checks for Java 21+, but its OSGi bundles declare what they really need
-- and the server exits with code 13 when the runtime is older.
local function required_from(stdout)
  local max
  for v in stdout:gmatch("osgi%.ee=JavaSE%)%(version=(%d+)") do
    max = math.max(max or 0, tonumber(v))
  end
  for v in stdout:gmatch("JavaSE%-(%d+)") do
    max = math.max(max or 0, tonumber(v))
  end
  return max
end

-- Manifests wrap long lines, so whitespace is stripped before matching.
local function manifest_cmd()
  local dir = vim.fn.stdpath("data") .. "/mason/packages/jdtls/plugins"
  if vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  return {
    "sh",
    "-c",
    'for j in "$1"/*.jar; do unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null; done | tr -d "\\r\\n "',
    "sh",
    dir,
  }
end

---@param cb? fun(required: integer|nil)
---@return integer|nil required when called without a callback
function M.jdtls_required(cb)
  local cmd = manifest_cmd()
  if not cmd then
    if cb then
      cb(nil)
    end
    return nil
  end
  if cb then
    vim.system(cmd, { text = true }, function(r)
      vim.schedule(function()
        cb(required_from(r.stdout or ""))
      end)
    end)
    return
  end
  return required_from(vim.system(cmd, { text = true }):wait().stdout or "")
end

---@return string|nil problem
function M.jdtls_problem(required)
  if vim.fn.executable(M.jdtls_java) == 0 then
    return ("jdtls JDK missing at %s; run home-manager switch"):format(M.jdtls_jdk)
  end
  local have = M.major(M.jdtls_jdk)
  if required and have and have < required then
    return ("jdtls %s needs Java %d but %s is Java %d: %s"):format(
      M.jdtls_version() or "?",
      required,
      M.jdtls_jdk,
      have,
      M.nix_hint
    )
  end
end

return M

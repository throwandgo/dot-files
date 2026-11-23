-- Makes the Scala/Java LSP setup fail loudly instead of silently degrading.
--
-- Everything in plugins/scala.lua and plugins/java.lua leans on plugin internals or on Metals
-- behaviour that has changed before. Each patch records whether it applied, and attached clients
-- are checked against the expected build root. Problems show as notifications at the moment they
-- happen, and `:checkhealth scala` lists them.
local build_root = require("utils.build_root")
local jdk = require("scala.jdk")

local M = {}

---@type table<string, { ok: boolean, msg: string }>
M.patches = {}
---@type { kind: string, msg: string }[]
M.problems = {}

local notified = {}
local function notify(msg, level)
  if notified[msg] then
    return
  end
  notified[msg] = true
  vim.schedule(function()
    vim.notify(msg, level, { title = "Scala/Java LSP" })
  end)
end

local function patch(name, ok, msg)
  M.patches[name] = { ok = ok and true or false, msg = msg }
  if not ok then
    notify(("Patch `%s` no longer applies: %s"):format(name, msg), vim.log.levels.WARN)
  end
  return ok
end

---@param kind string
---@param msg string
function M.problem(kind, msg)
  table.insert(M.problems, { kind = kind, msg = msg })
  notify(msg, vim.log.levels.ERROR)
end

-- Prompts that autoImportBuilds/targetBuildTool exist to suppress (Metals' Messages.scala:
-- ImportBuild, ImportBuildChanges, ChooseBuildTool).
local function is_suppressed_prompt(params)
  if (params.message or ""):find("Multiple build definitions found", 1, true) then
    return true
  end
  for _, action in ipairs(params.actions or {}) do
    if action.title == "Import build" or action.title == "Import changes" then
      return true
    end
  end
  return false
end

---@param metals_config table nvim-metals config, before initialize_or_attach
function M.patch_metals(metals_config)
  -- nvim-metals forwards $JAVA_OPTS/$JAVA_FLAGS to Metals as -J flags on top of cmd_env.
  local ok, jvmopts = pcall(require, "metals.jvmopts")
  if
    patch(
      "metals.jvmopts",
      ok and type(jvmopts.java_opts) == "function" and type(jvmopts.java_opts_from_file) == "function",
      "nvim-metals reorganized metals/jvmopts.lua, so $JAVA_OPTS (e.g. from ~/site/.envrc) may leak into Metals"
    )
  then
    jvmopts.java_opts = jvmopts.java_opts_from_file
  end

  -- Real Metals settings missing from nvim-metals' allowlist (it warns on unknown keys).
  local okc, config = pcall(require, "metals.config")
  local valid = okc and config.valid_metals_settings
  if
    patch(
      "metals.valid_metals_settings",
      type(valid) == "table",
      "nvim-metals no longer exports its settings allowlist; expect 'unknown setting' warnings"
    )
  then
    for _, key in ipairs({ "autoImportBuilds", "targetBuildTool" }) do
      if not vim.tbl_contains(valid, key) then
        table.insert(valid, key)
      end
    end
  end

  metals_config.handlers = metals_config.handlers or {}
  local show_request = metals_config.handlers["window/showMessageRequest"]
  metals_config.handlers["window/showMessageRequest"] = function(err, params, ctx, ...)
    if params and is_suppressed_prompt(params) then
      M.problem(
        "metals-prompt",
        ("Metals asked %q: settings.autoImportBuilds/targetBuildTool were ignored (renamed upstream?)"):format(
          params.message
        )
      )
    end
    return (show_request or vim.lsp.handlers["window/showMessageRequest"])(err, params, ctx, ...)
  end
end

-- LazyVim attaches jdtls to every Java buffer, and nvim-jdtls falls back to the .git root (the
-- whole monorepo) when root_dir is nil. Skip those buffers; Metals owns Java in sbt builds.
function M.gate_jdtls()
  local ok, jdtls = pcall(require, "jdtls")
  if
    not patch(
      "jdtls.start_or_attach",
      ok and type(jdtls.start_or_attach) == "function",
      "nvim-jdtls changed; Java files outside Gradle/Maven builds may start jdtls on the repo root"
    )
  then
    return
  end
  if jdtls._root_gated then
    return
  end
  local start_or_attach = jdtls.start_or_attach
  jdtls.start_or_attach = function(config, ...)
    if config and config.root_dir then
      return start_or_attach(config, ...)
    end
  end
  jdtls._root_gated = true
end

---@param project_name string|nil
function M.jdtls_on_exit(project_name)
  return function(code, signal)
    -- Runs in a fast event context, where most of the API is off limits.
    vim.schedule(function()
      if code == 0 or signal ~= 0 or vim.v.exiting ~= vim.NIL then
        return
      end
      local log = project_name and (vim.fn.stdpath("cache") .. "/jdtls/" .. project_name .. "/config/*.log")
      -- Exit 13 is the Equinox launcher failing to resolve bundles, usually a Java version mismatch.
      local why = code == 13 and jdk.jdtls_problem(jdk.jdtls_required()) or nil
      if code == 13 and not why and log then
        for _, file in ipairs(vim.fn.glob(log, false, true)) do
          local need = table.concat(vim.fn.readfile(file), "\n"):match("osgi%.ee=JavaSE%)%(version=(%d+)")
          why = need and ("It needs Java %s but was launched with an older one (see %s)"):format(need, file) or why
        end
      end
      M.problem("jdtls-exit", ("jdtls exited with code %d. %s"):format(code, why or ("See " .. (log or "jdtls logs"))))
    end)
  end
end

local function check_attach(client, buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if not vim.startswith(path, "/") then
    return -- jdt://, zipfile://, ...
  end
  local expected = client.name == "metals" and build_root.metals_root(path) or build_root.jdtls_root(path)
  local actual = client.root_dir or client.config.root_dir
  if expected ~= actual then
    M.problem(
      "root",
      ("%s attached to %s with root %s, expected %s"):format(
        client.name,
        vim.fn.fnamemodify(path, ":~:."),
        actual and vim.fn.fnamemodify(actual, ":~") or "nil",
        expected and vim.fn.fnamemodify(expected, ":~") or "no server"
      )
    )
  end
  if client.name == "metals" and vim.env.JAVA_OPTS and vim.env.JAVA_OPTS ~= "" then
    local env = client.config.cmd_env or {}
    if env.JAVA_OPTS ~= "" then
      M.problem("metals-env", "Metals was started without cmd_env.JAVA_OPTS = '', so $JAVA_OPTS leaks into it")
    end
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("scala_guards", { clear = true }),
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and (client.name == "metals" or client.name == "jdtls") then
        check_attach(client, ev.buf)
      end
    end,
  })
end

-- Mason upgrades jdtls independently of home-manager's JDK.
function M.check_jdtls_jdk()
  jdk.jdtls_required(function(required)
    local problem = jdk.jdtls_problem(required)
    if problem then
      M.problem("jdtls-jdk", problem)
    end
  end)
end

function M.watch_mason()
  local ok, registry = pcall(require, "mason-registry")
  if
    patch(
      "mason-registry.on",
      ok and type(registry.on) == "function",
      "mason-registry has no event API; jdtls upgrades won't be checked against the jdtls JDK"
    )
  then
    registry:on("package:install:success", function(pkg)
      if pkg.name == "jdtls" then
        vim.schedule(M.check_jdtls_jdk)
      end
    end)
  end
end

return M

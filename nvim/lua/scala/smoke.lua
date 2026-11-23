-- End-to-end check of the Scala/Java LSP setup against a throwaway fixture (scala/fixture.lua),
-- with real Metals, Bloop, sbt and jdtls. Runs in a separate headless nvim:
--   :ScalaSmokeTest               (background; also runs after :Lazy update / :Lazy sync)
--   nvim/scripts/scala-smoke.sh   (foreground; exits non-zero on failure)
local M = {}

M.log = vim.fn.stdpath("state") .. "/scala-smoke.log"
M.result_file = vim.fn.stdpath("state") .. "/scala-smoke.json"

-- A heavy, app-style JAVA_OPTS like ~/site/.envrc exports; none of it may reach Metals.
M.leaky_java_opts = "-Xms1g -Dplay.smoke=leaked"

local TIMEOUT_MS = 6 * 60 * 1000

-- Identifies the plugin + server versions a result applies to.
function M.lock_hash()
  local lock = vim.fn.stdpath("config") .. "/lazy-lock.json"
  local lines = vim.fn.filereadable(lock) == 1 and vim.fn.readfile(lock) or {}
  return vim.fn.sha256(table.concat(lines, "\n") .. (require("scala.jdk").jdtls_version() or ""))
end

---@return { ok: boolean, failures: string[], time: integer, seconds: integer, lock: string }|nil
function M.last_result()
  if vim.fn.filereadable(M.result_file) == 0 then
    return nil
  end
  local ok, result = pcall(vim.json.decode, table.concat(vim.fn.readfile(M.result_file), "\n"))
  return ok and result or nil
end

local running = false

-- Runs the smoke test in a background nvim and notifies with the result.
function M.spawn()
  if running then
    return vim.notify("Scala smoke test already running", vim.log.levels.INFO, { title = "Scala smoke test" })
  end
  running = true
  vim.notify("Running in the background (usually under a minute)", vim.log.levels.INFO, { title = "Scala smoke test" })
  local log = assert(io.open(M.log, "w"))
  local function write(_, data)
    if data then
      log:write(data)
    end
  end
  vim.system({ vim.v.progpath, "--headless", "-c", "lua require('scala.smoke').run()" }, {
    stdout = write,
    stderr = write,
  }, function(r)
    log:close()
    vim.schedule(function()
      running = false
      local result = M.last_result()
      if r.code == 0 and result and result.ok then
        vim.notify(("Passed in %ds"):format(result.seconds), vim.log.levels.INFO, { title = "Scala smoke test" })
      else
        local failures = result and not result.ok and result.failures or { "exit code " .. r.code }
        vim.notify(
          ("FAILED:\n- %s\n\nLog: %s"):format(table.concat(failures, "\n- "), M.log),
          vim.log.levels.ERROR,
          { title = "Scala smoke test" }
        )
      end
    end)
  end)
end

local function out(msg)
  io.stdout:write(os.date("%H:%M:%S ") .. msg .. "\n")
  io.stdout:flush()
end

local function lsp_clients(name)
  return vim.lsp.get_clients({ name = name })
end

local function wait(ms, cond)
  return vim.wait(ms, cond, 200)
end

-- Polls a request until `accept` approves a result.
local function poll(buf, method, params_fn, accept, ms)
  local found
  wait(ms, function()
    local res = vim.lsp.buf_request_sync(buf, method, params_fn(), 10000) or {}
    for _, r in pairs(res) do
      if r.result and accept(r.result) then
        found = r.result
        return true
      end
    end
    vim.wait(1500)
    return false
  end)
  return found
end

local function position_of(buf, line, word)
  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
  return {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = line, character = assert(text:find(word, 1, true)) - 1 },
  }
end

-- JVM command lines of the Metals servers this nvim started.
local function metals_jvms()
  local children, cmds = {}, {}
  for _, line in ipairs(vim.fn.systemlist({ "ps", "-axo", "pid=,ppid=,command=" })) do
    local pid, ppid, cmd = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], { pid = pid, cmd = cmd })
    end
  end
  local function walk(pid)
    for _, child in ipairs(children[pid] or {}) do
      if child.cmd:match("java") and child.cmd:find("/nvim-metals/metals", 1, true) then
        table.insert(cmds, child.cmd)
      end
      walk(child.pid)
    end
  end
  walk(tostring(vim.fn.getpid()))
  return cmds
end

local function steps(dir, check)
  local guards = require("scala.guards")

  -- Answering prompts would block a headless nvim; guards still records them as problems.
  vim.lsp.handlers["window/showMessageRequest"] = function()
    return vim.NIL
  end

  -- lazy.nvim fires VeryLazy on UIEnter, which never happens headless.
  if not vim.g.did_very_lazy then
    vim.g.did_very_lazy = true
    vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  end

  check(vim.tbl_get(_G, "LazyVim", "pick", "picker", "name") == "snacks", "picker is snacks")

  if vim.fn.executable("zoekt-webserver") == 1 then
    local err, status, list = require("search.zoekt").post_sync("/api/list", { Q = "" }, 2000)
    local repos = vim.tbl_get(list or {}, "List", "Repos") or {}
    check(not err and status == 200 and #repos > 0, ("zoekt serves an index (%s)"):format(err or status))
  end

  local root_failures = require("scala.fixture").check_roots(dir)
  check(#root_failures == 0, "build roots: " .. (#root_failures == 0 and "ok" or table.concat(root_failures, "; ")))

  -- Metals on a Scala file of a nested sbt subproject.
  local sbt_root = dir .. "/sbt"
  vim.cmd.edit(sbt_root .. "/modules/app/src/main/scala/smoke/Main.scala")
  local main = vim.api.nvim_get_current_buf()
  local attached = wait(120000, function()
    return #lsp_clients("metals") > 0 and vim.lsp.buf_is_attached(main, lsp_clients("metals")[1].id)
  end)
  if not check(attached, "metals attaches to Main.scala") then
    return
  end
  local metals = lsp_clients("metals")
  check(#metals == 1, ("exactly one metals client (got %d)"):format(#metals))
  check(
    vim.fn.maparg(" sS", "n", false, true).desc == "Symbols (repo, indexed)",
    "<leader>sS stays repo-wide symbols in LSP buffers"
  )
  check(metals[1].root_dir == sbt_root, ("metals root is the aggregating build (got %s)"):format(metals[1].root_dir))
  for name, r in pairs(guards.patches) do
    check(r.ok, ("patch %s applies"):format(name))
  end

  local jvms = metals_jvms()
  check(#jvms == 1, ("one Metals JVM (got %d)"):format(#jvms))
  for _, cmd in ipairs(jvms) do
    check(not cmd:find("play.smoke", 1, true) and not cmd:find("-Xms1g", 1, true), "$JAVA_OPTS kept out of Metals")
    check(cmd:find("-Xmx6G", 1, true) ~= nil, "Metals JVM has -Xmx6G")
  end

  -- Cross-file navigation only works once the build is imported (no prompt) and compiled.
  local def = poll(main, "textDocument/definition", function()
    return position_of(main, 4, "Helper")
  end, function(result)
    local loc = vim.islist(result) and result[1] or result
    return loc ~= nil and (loc.uri or loc.targetUri or ""):match("Helper%.scala$") ~= nil
  end, 240000)
  check(def ~= nil, "definition of Helper resolves (build imported via Bloop)")
  check(
    (vim.g.metals_bsp_status or ""):match("Bloop") or vim.fn.isdirectory(sbt_root .. "/.bloop") == 1,
    "Bloop is the build server"
  )

  -- Inlay hints: inferred types only (`total: Int`), no implicit plumbing (`(using Numeric)`).
  local function labels(hints)
    local ret = {}
    for _, h in ipairs(hints or {}) do
      local label = h.label
      if type(label) == "table" then
        label = table.concat(vim.tbl_map(function(part)
          return part.value
        end, label))
      end
      ret[#ret + 1] = label
    end
    return table.concat(ret, " ")
  end
  local hints = poll(main, "textDocument/inlayHint", function()
    return {
      textDocument = vim.lsp.util.make_text_document_params(main),
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 7, character = 0 } },
    }
  end, function(result)
    return labels(result):find("Int") ~= nil
  end, 30000)
  check(hints ~= nil, "inlay hint shows the inferred type of total")
  local extra = hints and vim.trim(labels(hints):gsub(":%s*%S+", "")) or ""
  check(hints ~= nil and extra == "", ("no implicit-argument hints (got %q)"):format(hints and labels(hints) or ""))

  -- gas follows the definition into generated code and on to the .proto it came from.
  vim.api.nvim_set_current_buf(main)
  vim.api.nvim_win_set_cursor(0, { 7, ("  val greeting: Greeting = "):len() })
  require("understand").source()
  local landed = wait(30000, function()
    return vim.api.nvim_buf_get_name(0):match("greeting%.proto$") ~= nil
  end)
  check(
    landed and vim.api.nvim_get_current_line():match("^message Greeting") ~= nil,
    ("gas: Greeting -> greeting.proto (got %s:%d)"):format(
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
      vim.api.nvim_win_get_cursor(0)[1]
    )
  )
  vim.api.nvim_set_current_buf(main)

  -- Impact (<leader>gi) maps changed lines to enclosing definitions with treesitter; grammar drift
  -- would silently empty it.
  local names = require("review.impact").definitions(dir .. "/sbt/modules/app", {
    ["src/main/scala/smoke/Main.scala"] = { 6 },
    ["src/main/scala/smoke/Helper.scala"] = { 4 },
    ["src/main/protobuf/greeting.proto"] = { 4, 5 },
    ["src/main/java/smoke/Util.java"] = { 3 },
  })
  local got = table.concat(names, " ")
  check(
    got == "Greeting Util getText greet setText text total withText",
    ("impact: changed lines -> definitions and generated names (got %q)"):format(got)
  )

  -- Code-understanding features (gai, gap/gac) lean on Metals' call and type hierarchy.
  local incoming = poll(main, "textDocument/prepareCallHierarchy", function()
    return position_of(main, 4, "run")
  end, function(result)
    return #result > 0
  end, 30000)
  local callers = incoming
      and vim.lsp.buf_request_sync(main, "callHierarchy/outgoingCalls", { item = incoming[1] }, 10000)
    or {}
  local calls_helper = false
  for _, r in pairs(callers) do
    for _, call in ipairs(r.result or {}) do
      calls_helper = calls_helper or call.to.name == "greet"
    end
  end
  check(calls_helper, "call hierarchy: run calls greet")

  vim.cmd.edit(sbt_root .. "/modules/app/src/main/scala/smoke/Greeter.scala")
  local greeter = vim.api.nvim_get_current_buf()
  local subtypes
  wait(30000, function()
    local done = false
    require("understand.hierarchy").collect(
      metals[1],
      greeter,
      position_of(greeter, 2, "Greeter"),
      "subtypes",
      function(nodes)
        subtypes = nodes and vim.tbl_map(function(n)
          return n.item.name
        end, nodes)
        done = true
      end
    )
    wait(10000, function()
      return done
    end)
    return subtypes ~= nil and vim.tbl_contains(subtypes, "Helper")
  end)
  check(
    subtypes ~= nil and vim.tbl_contains(subtypes, "Helper"),
    ("type hierarchy: Helper extends Greeter (got %s)"):format(vim.inspect(subtypes))
  )

  -- Java inside an sbt build goes to Metals, not jdtls.
  vim.cmd.edit(sbt_root .. "/modules/app/src/main/java/smoke/Util.java")
  local util = vim.api.nvim_get_current_buf()
  wait(5000, function()
    return vim.lsp.buf_is_attached(util, metals[1].id)
  end)
  check(vim.lsp.buf_is_attached(util, metals[1].id), "metals takes Java inside the sbt build")
  check(#lsp_clients("jdtls") == 0, "no jdtls for Java inside the sbt build")

  -- Scala outside any build starts nothing.
  vim.cmd.edit(dir .. "/loose/Loose.scala")
  vim.wait(3000)
  check(#lsp_clients("metals") == 1, "no Metals for Scala outside a build")

  -- jdtls on a Maven project.
  local maven_root = dir .. "/maven"
  vim.cmd.edit(maven_root .. "/src/main/java/smoke/App.java")
  local app = vim.api.nvim_get_current_buf()
  local jdtls_up = wait(120000, function()
    local c = lsp_clients("jdtls")[1]
    return c ~= nil and c.initialized and vim.lsp.buf_is_attached(app, c.id)
  end)
  if check(jdtls_up, "jdtls starts on the Maven project") then
    check(lsp_clients("jdtls")[1].root_dir == maven_root, "jdtls root is the Maven project")
    local symbols = poll(app, "textDocument/documentSymbol", function()
      return { textDocument = vim.lsp.util.make_text_document_params(app) }
    end, function(result)
      return #result > 0
    end, 120000)
    check(symbols ~= nil, "jdtls answers documentSymbol")
  end

  for _, p in ipairs(guards.problems) do
    check(false, ("[%s] %s"):format(p.kind, p.msg))
  end
end

-- Entry point for the headless nvim.
function M.run()
  local start = os.time()
  local failures = {}
  local function check(ok, msg)
    out((ok and "ok   " or "FAIL ") .. msg)
    if not ok then
      table.insert(failures, msg)
    end
    return ok
  end

  -- Set before any server starts; plugins/scala.lua reads it when nvim-metals loads.
  vim.env.JAVA_OPTS = M.leaky_java_opts

  local base = vim.fn.stdpath("cache") .. "/scala-smoke"
  local dir = base .. "/" .. start
  require("scala.fixture").create(dir)
  dir = assert(vim.uv.fs_realpath(dir))
  vim.fn.chdir(dir)
  out("fixture " .. dir)

  local timer = assert(vim.uv.new_timer())
  timer:start(TIMEOUT_MS, 0, function()
    io.stdout:write("FAIL timed out\n")
    os.exit(2)
  end)
  local ok, err = xpcall(steps, debug.traceback, dir, check)
  if not ok then
    check(false, "error: " .. tostring(err))
  end
  timer:stop()

  -- Shut servers down before deleting their workspaces.
  local clients = vim.lsp.get_clients()
  for _, c in ipairs(clients) do
    c:stop()
  end
  wait(15000, function()
    return #vim.lsp.get_clients() == 0
  end)
  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop(true)
  end
  vim.fn.chdir(vim.env.HOME)
  vim.fn.delete(base, "rf")
  vim.fn.delete(vim.fn.stdpath("cache") .. "/jdtls/" .. require("scala.jdk").jdtls_project_name(dir .. "/maven"), "rf")

  local result = {
    ok = #failures == 0,
    failures = failures,
    time = start,
    seconds = os.time() - start,
    lock = M.lock_hash(),
  }
  vim.fn.writefile({ vim.json.encode(result) }, M.result_file)
  out(("%s in %ds"):format(result.ok and "PASSED" or "FAILED", result.seconds))
  vim.cmd(result.ok and "qall!" or "cquit 1")
end

function M.setup()
  vim.api.nvim_create_user_command("ScalaSmokeTest", M.spawn, { desc = "Smoke-test Metals/jdtls in the background" })
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("scala_smoke", { clear = true }),
    pattern = { "LazyUpdate", "LazySync" },
    callback = function()
      -- Let lazy finish rebuilding plugins first.
      vim.defer_fn(M.spawn, 2000)
    end,
  })
end

return M

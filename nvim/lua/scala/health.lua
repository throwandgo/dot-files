-- :checkhealth scala
local M = {}

local h = vim.health

local function tail_lines(path, max_bytes)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - max_bytes))
  local s = f:read("*a")
  f:close()
  return vim.split(s, "\n", { plain = true })
end

-- Last build import and build server, from the workspace's .metals/metals.log.
local function metals_log_status(root)
  local lines = tail_lines(root .. "/.metals/metals.log", 2 * 1024 * 1024)
  if not lines then
    return h.info(("%s: no .metals/metals.log yet"):format(vim.fn.fnamemodify(root, ":~")))
  end
  local server, import_failed, cause, imported
  for _, line in ipairs(lines) do
    server = line:match("Connected to Build server: (.+)$") or server
    if line:match("running '.*bloopInstall") or line:match("running '.*gradle") then
      import_failed, cause, imported = false, nil, false
    elseif line:match("%[error%] %(") then
      cause = line:match("%[error%] (.*)$")
    elseif line:match("ERROR sbt command failed") or line:match("ERROR .*[Ii]mport.* failed") then
      import_failed = true
    elseif line:match("time: ran 'sbt bloopInstall'") or line:match("time: imported build") then
      imported = true
    end
  end
  local name = vim.fn.fnamemodify(root, ":~")
  if import_failed then
    h.error(("%s: last build import failed%s"):format(name, cause and (": " .. cause) or ""), {
      "Fix the error (often a local DB/Flyway task run during import), then :MetalsImportBuild",
      "Make sure shared infra is up: make -C metropolis/infrastructure up",
    })
  elseif imported then
    h.ok(("%s: build imported"):format(name))
  end
  if server and server:match("^sbt") then
    h.warn(("%s: build server is %s (slower and heavier than Bloop)"):format(name, server), {
      ":MetalsSwitchBsp and pick Bloop",
    })
  elseif server then
    h.ok(("%s: build server %s"):format(name, server))
  end
end

local function check_editor()
  h.start("Editor")
  local picker = vim.tbl_get(_G, "LazyVim", "pick", "picker", "name")
  if picker == "snacks" then
    h.ok("Picker: snacks")
  else
    h.warn(("Picker: %s (fzf-lua greps are slow in the monorepo)"):format(picker or "not loaded yet"), {
      'Set vim.g.lazyvim_picker = "snacks" in lua/config/options.lua',
    })
  end
end

local function check_guards()
  local guards = require("scala.guards")
  h.start("Patches on plugin internals")
  if vim.tbl_isempty(guards.patches) then
    h.info("None applied yet (they apply when nvim-metals / nvim-jdtls / mason load)")
  end
  for name, r in vim.spairs(guards.patches) do
    if r.ok then
      h.ok(name)
    else
      h.error(("%s: %s"):format(name, r.msg), { "Re-check lua/plugins/scala.lua and lua/scala/guards.lua" })
    end
  end
  h.start("Problems seen this session")
  if #guards.problems == 0 then
    h.ok("None")
  end
  for _, p in ipairs(guards.problems) do
    h.error(("[%s] %s"):format(p.kind, p.msg))
  end
end

local function check_runtimes()
  local jdk = require("scala.jdk")
  h.start("Java")
  local project = jdk.project_jdk()
  if project then
    h.ok(("Project JDK: Java %s (%s)"):format(jdk.major(project) or "?", project))
  else
    h.error("No project JDK: set JAVA_HOME or install a JDK")
  end
  if vim.env.JAVA_OPTS and vim.env.JAVA_OPTS ~= "" then
    h.info("$JAVA_OPTS is set; it's kept out of Metals (cmd_env) and passed to sbt via SBT_OPTS")
  end

  local metals = vim.fn.stdpath("cache") .. "/nvim-metals/metals"
  if vim.fn.executable(metals) == 1 then
    h.ok("Metals installed")
  else
    h.warn("Metals not installed yet", { ":MetalsInstall" })
  end

  local version = jdk.jdtls_version()
  if not version then
    return h.info("jdtls not installed (Mason installs it on first Java file)")
  end
  local required = jdk.jdtls_required()
  local problem = jdk.jdtls_problem(required)
  if problem then
    h.error(problem)
  else
    h.ok(
      ("jdtls %s needs Java %s; jdtls JDK is Java %s"):format(version, required or "?", jdk.major(jdk.jdtls_jdk) or "?")
    )
  end
end

local function check_clients()
  local build_root = require("utils.build_root")
  h.start("Language servers")
  local clients = vim.list_extend(vim.lsp.get_clients({ name = "metals" }), vim.lsp.get_clients({ name = "jdtls" }))
  if #clients == 0 then
    h.info("No metals/jdtls clients (open a .scala or .java file in a build)")
  end
  local seen = {}
  for _, client in ipairs(clients) do
    local root = client.root_dir or client.config.root_dir
    local is_root = root
      and (
        client.name == "metals" and (build_root.is_sbt_root(root) or build_root.is_gradle_root(root))
        or client.name == "jdtls" and (build_root.is_gradle_root(root) or build_root.is_maven_root(root))
      )
    local msg = ("%s #%d at %s (%d buffers)"):format(
      client.name,
      client.id,
      root and vim.fn.fnamemodify(root, ":~") or "nil",
      vim.tbl_count(client.attached_buffers)
    )
    if is_root then
      h.ok(msg)
    else
      h.error(msg .. ": not a build root")
    end
    if client.name == "metals" and root and not seen[root] then
      seen[root] = true
      metals_log_status(root)
    end
  end
end

local function check_reaper()
  local reaper = require("scala.reaper")
  h.start("Idle server reaper")
  local minutes = reaper.minutes()
  if minutes <= 0 then
    h.info("Disabled (vim.g.lsp_reaper_minutes = 0)")
  else
    h.ok(
      ("Stops %s after %d min with none of their files visible (vim.g.lsp_reaper_minutes)"):format(
        table.concat(reaper.names, "/"),
        minutes
      )
    )
  end
  for _, r in ipairs(reaper.reaped) do
    h.info(("Stopped %s at %s on %s"):format(r.name, vim.fn.fnamemodify(r.root, ":~"), os.date("%H:%M", r.at)))
  end
end

local function check_root_finder()
  local fixture = require("scala.fixture")
  h.start("Build root detection")
  local dir = vim.fn.tempname()
  fixture.create(dir)
  local failures = fixture.check_roots(dir)
  vim.fn.delete(dir, "rf")
  if #failures == 0 then
    h.ok("Fixture roots resolve as expected")
  end
  for _, f in ipairs(failures) do
    h.error(f)
  end
end

local function check_smoke()
  local smoke = require("scala.smoke")
  h.start("Smoke test")
  local last = smoke.last_result()
  if not last then
    return h.warn("Never run", { ":ScalaSmokeTest" })
  end
  local when = os.date("%Y-%m-%d %H:%M", last.time)
  if not last.ok then
    h.error(("Failed on %s"):format(when), vim.list_extend(vim.deepcopy(last.failures), { "Log: " .. smoke.log }))
  elseif last.lock ~= smoke.lock_hash() then
    h.warn(("Passed on %s, but plugins changed since"):format(when), { ":ScalaSmokeTest" })
  else
    h.ok(("Passed on %s in %ds"):format(when, last.seconds or 0))
  end
end

function M.check()
  check_editor()
  check_guards()
  check_runtimes()
  check_clients()
  check_reaper()
  check_root_finder()
  check_smoke()
end

return M
